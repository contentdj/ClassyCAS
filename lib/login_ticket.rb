class LoginTicket
  class << self
    def validate!(ticket, store)
      if store.key? ticket
        store.delete ticket
        new
      end
    end
    
    def expire_time
      300
    end
  end
  
  def ticket
    @ticket ||= "LT-#{rand(100000000000000000)}".to_s
  end
  
  def remaining_time(store)
    store.ttl ticket
  end
  
  def save!(store)
    store[ticket] = 1
    store.expire ticket, self.class.expire_time
  end
end