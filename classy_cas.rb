require 'rubygems'
require "bundler/setup"

require 'sinatra'

require 'redis'
require 'haml'
require 'addressable/uri'
require 'nokogiri'

require 'lib/login_ticket'
require 'lib/proxy_ticket'
require 'lib/service_ticket'
require 'lib/ticket_granting_ticket'
require 'lib/user_store'

configure do
  if ENV['RACK_ENV'] == 'production'
    require 'redis'
    uri = URI.parse('redis://heroku:60805d87e9dc1626bd64928253407933@goosefish.redistogo.com:9787/')
    REDIS = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
  end
end

before do
  if ENV['RACK_ENV'] == 'production'
    @redis = REDIS
  else
    @redis ||= Redis.new
  end
end


get "/login" do
  @service_url = Addressable::URI.parse(params[:service])
  @renew = [true, "true", "1", 1].include?(params[:renew])
  @gateway = [true, "true", "1", 1].include?(params[:gateway])

  if @renew
    @login_ticket = LoginTicket.create!(@redis)
    haml :login
  elsif @gateway
    if @service_url
      if sso_session
        st = ServiceTicket.new(params[:service], sso_session.username)
        st.save!(@redis)
        redirect_url = @service_url.clone
        if @service_url.query_values.nil?
          redirect_url.query_values = @service_url.query_values = {:ticket => st.ticket}
        else
          redirect_url.query_values = @service_url.query_values.merge(:ticket => st.ticket)
        end
        redirect redirect_url.to_s, 303
      else
        redirect @service_url.to_s, 303
      end
    else
      @login_ticket = LoginTicket.create!(@redis)
      haml :login
    end
  else
    if sso_session
      if @service_url
        st = ServiceTicket.new(params[:service], sso_session.username)
        st.save!(@redis)
        redirect_url = @service_url.clone
        if @service_url.query_values.nil?
          redirect_url.query_values = @service_url.query_values = {:ticket => st.ticket}
        else
          redirect_url.query_values = @service_url.query_values.merge(:ticket => st.ticket)
        end
        redirect redirect_url.to_s, 303
      else
        return haml :already_logged_in
      end
    else
      @login_ticket = LoginTicket.create!(@redis)
      haml :login
    end
  end
end

post "/login" do
  username = params[:username]
  password = params[:password]

  service_url = params[:service]

  warn = [true, "true", "1", 1].include? params[:warn]

  # Spec is undefined about what to do without these params, so redirecting to credential requestor
  redirect "/login", 303 unless username && password && login_ticket

  if UserStore.authenticate(username, password)
    tgt = TicketGrantingTicket.new(username)
    tgt.save!(@redis)
    cookie = tgt.to_cookie(request.host)
    response.set_cookie(cookie[0], cookie[1])

    if service_url && !warn
      st = ServiceTicket.new(service_url, username)
      st.save!(@redis)
      redirect service_url + "?ticket=#{st.ticket}", 303
    else
      haml :logged_in
    end
  else
    redirect "/login", 303
  end
end

get %r{(proxy|service)Validate} do
  service_url = params[:service]
  ticket = params[:ticket]
  # proxy_gateway = params[:pgtUrl]
  # renew = params[:renew]

  xml = if service_url && ticket
  if service_ticket
    if service_ticket.valid_for_service?(service_url)
      render_validation_success service_ticket.username
    else
      render_validation_error(:invalid_service)
    end
  else
    render_validation_error(:invalid_ticket, "ticket #{ticket} not recognized")
  end
  else
    render_validation_error(:invalid_request)
  end

  content_type :xml
  xml
end


get '/logout' do
  if sso_session
    @sso_session.destroy!(@redis)
  end
end


private
  def sso_session
    @sso_session ||= TicketGrantingTicket.validate(request.cookies["tgt"], @redis)
  end
  
  def ticket_granting_ticket
    @ticket_granting_ticket = sso_session
    @ticket_granting_ticket
  end
  def login_ticket
    @login_ticket ||= LoginTicket.validate!(params[:lt], @redis)
  end

  def service_ticket
    @service_ticket ||= ServiceTicket.find!(params[:ticket], @redis)
  end

  def render_validation_error(code, message = nil)
    xml = Nokogiri::XML::Builder.new do |xml|
      xml.serviceResponse("xmlns:cas" => "http://www.yale.edu/tp/cas") {
        xml['cas'].authenticationFailure(message, :code => code.to_s.upcase){
        }
      }
    end
    namespace_hack(xml)
  end

  def render_validation_success(username)
    xml = Nokogiri::XML::Builder.new do |xml|
      xml.serviceResponse("xmlns:cas" => "http://www.yale.edu/tp/cas") {
        xml['cas'].authenticationSuccess {
          xml['cas'].user username
        }
      }
    end
    namespace_hack(xml)
  end



  #Nokogiri will not allow a namespace to be used before
  #It's declared, why this is I don't know.
  def namespace_hack(xml)
    result = xml.to_xml
    result = result.gsub(/serviceResponse/, 'cas:serviceResponse')
    result
  end
