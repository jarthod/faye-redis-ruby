require 'em-hiredis'
require 'multi_json'

module Faye
  class Redis
    DEFAULT_HOST     = 'localhost'
    DEFAULT_PORT     = 6379
    DEFAULT_DATABASE = 0
    DEFAULT_GC       = 60
    LOCK_TIMEOUT     = 120

    def self.create(server, options)
      new(server, options)
    end

    def initialize(server, options)
      @server  = server
      @options = options
      @ns = @options[:namespace] || ''
      @message_channel = @ns + '/notifications/messages'
      @close_channel   = @ns + '/notifications/close'
      redis if EventMachine.reactor_running?
    end

    def disconnect
      return unless @redis
      @subscriber.unsubscribe(@message_channel)
      @subscriber.unsubscribe(@close_channel)
      EventMachine.cancel_timer(@gc)
    end

    def create_client(&callback)
      client_id = @server.generate_id
      redis.zadd(@ns + '/clients', get_current_time, client_id) do |added|
        next create_client(&callback) if added == 0
        @server.debug 'Created new client ?', client_id
        ping(client_id)
        @server.trigger(:handshake, client_id)
        callback.call(client_id)
      end
    end

    def client_exists(client_id, timeout_multiplier = 1.6, &callback)
      cutoff = get_current_time - (1000 * timeout_multiplier * @server.timeout)

      redis.zscore(@ns + '/clients', client_id) do |score|
        callback.call(score.to_i > cutoff)
      end
    end

    def destroy_client(client_id, &callback)
      redis.zadd(@ns + '/clients', 0, client_id) do
        redis.smembers(@ns + "/clients/#{client_id}/channels") do |channels|
          i, n = 0, channels.size
          next after_subscriptions_removed(client_id, &callback) if i == n

          channels.each do |channel|
            unsubscribe(client_id, channel) do
              i += 1
              after_subscriptions_removed(client_id, &callback) if i == n
            end
          end
        end
      end
    end

    def after_subscriptions_removed(client_id, &callback)
      redis.del(@ns + "/clients/#{client_id}/messages") do
        redis.zrem(@ns + '/clients', client_id) do
          @server.debug 'Destroyed client ?', client_id
          @server.trigger(:disconnect, client_id)
          redis.publish(@close_channel, client_id)
          callback.call if callback
        end
      end
    end

    def ping(client_id)
      timeout = @server.timeout
      return unless Numeric === timeout

      time = get_current_time
      @server.debug 'Ping ?, ?', client_id, time
      redis.zadd(@ns + '/clients', time, client_id)
    end

    def subscribe(client_id, channel, &callback)
      redis.sadd(@ns + "/clients/#{client_id}/channels", channel) do |added|
        @server.trigger(:subscribe, client_id, channel) if added == 1
      end
      redis.sadd(@ns + "/channels#{channel}", client_id) do
        @server.debug 'Subscribed client ? to channel ?', client_id, channel
        callback.call if callback
      end
    end

    def unsubscribe(client_id, channel, &callback)
      redis.srem(@ns + "/clients/#{client_id}/channels", channel) do |removed|
        @server.trigger(:unsubscribe, client_id, channel) if removed == 1
      end
      redis.srem(@ns + "/channels#{channel}", client_id) do
        @server.debug 'Unsubscribed client ? from channel ?', client_id, channel
        callback.call if callback
      end
    end

    def publish(message, channels)
      @server.debug 'Publishing message ?', message

      json_message = MultiJson.dump(message)
      channels     = Channel.expand(message['channel'])
      keys         = channels.map { |c| @ns + "/channels#{c}" }

      redis.sunion(*keys) do |clients|
        clients.each do |client_id|
          queue = @ns + "/clients/#{client_id}/messages"

          @server.debug 'Queueing for client ?: ?', client_id, message
          redis.rpush(queue, json_message)
          redis.publish(@message_channel, client_id)

          client_exists(client_id) do |exists|
            destroy_client(client_id) unless exists
          end
        end
      end

      @server.trigger(:publish, message['clientId'], message['channel'], message['data'])
    end

    def empty_queue(client_id)
      return unless @server.has_connection?(client_id)

      key = @ns + "/clients/#{client_id}/messages"

      redis.multi
      redis.lrange(key, 0, -1)
      redis.del(key)
      redis.exec.callback  do |json_messages, deleted|
        next unless json_messages
        messages = json_messages.map { |json| MultiJson.load(json) }
        if not @server.deliver(client_id, messages)
          redis.rpush(key, *json_messages)
        end
      end
    end

    private

    def redis
      @redis ||= begin
        uri              = @options[:uri]              || nil
        host             = @options[:host]             || DEFAULT_HOST
        port             = @options[:port]             || DEFAULT_PORT
        db               = @options[:database]         || DEFAULT_DATABASE
        auth             = @options[:password]         || nil
        gc               = @options[:gc]               || DEFAULT_GC
        socket           = @options[:socket]           || nil
        inactivity_check = @options[:inactivity_check] || {}

        connection = if uri
          EventMachine::Hiredis.connect(uri)
        elsif socket
          EventMachine::Hiredis::Client.new(socket, nil, auth, db).connect
        else
          EventMachine::Hiredis::Client.new(host, port, auth, db).connect
        end

        @gc = EventMachine.add_periodic_timer(gc, &method(:gc))
        @subscriber = connection.pubsub
        @subscriber.subscribe(@message_channel)
        @subscriber.subscribe(@close_channel)
        @subscriber.on(:message) do |topic, message|
          empty_queue(message) if topic == @message_channel
          @server.trigger(:close, message) if topic == @close_channel
        end
        register_connection_listeners('pubsub', @subscriber, "faye-server/#{@ns}/pubsub[#{Socket.gethostname}][#{Process.pid}]")
        register_connection_listeners('redis', connection, "faye-server/#{@ns}[#{Socket.gethostname}][#{Process.pid}]")
        if inactivity_check_enabled?(inactivity_check)
          @server.info "Faye::Redis: Configuring inactivity check for redis connection and pubsub with trigger_secs=#{inactivity_check[:trigger_secs]} and response_timeout=#{inactivity_check[:response_timeout]}"
          configure_inactivity_check(connection, inactivity_check)
          configure_inactivity_check(@subscriber, inactivity_check)
        end

        connection
      end
    end

    def register_connection_listeners(name, connection, connection_name)
      connection.on(:connected) do
        connection.client('setname', connection_name)
        @server.info "Faye::Redis: #{name} connection connected"
      end
      connection.on(:disconnected) do
        @server.info "Faye::Redis: #{name} connection disconnected"
      end
      connection.on(:reconnected) do
        @server.info "Faye::Redis: #{name} connection reconnected"
      end
      connection.on(:reconnect_failed) do |count|
        @server.info "Faye::Redis: #{name} connection reconnect failed #{count} time(s)"
        begin
          fn = @options[:reconnect_failed] || ->(_, _) {}
          fn.call(count, name)
        rescue => e
          @server.error "Faye::Redis: Execution of reconnect_failed lambda failed with #{e} (#{name} connection)"
        end
      end
      connection.on(:failed) do
        @server.error "Faye::Redis: #{name} connection failed"
      end
      connection.errback do |reason|
        @server.error "Faye::Redis: #{name} connection failed: #{reason}"
      end
    end

    def inactivity_check_enabled?(inactivity_check)
      inactivity_check[:trigger_secs] || inactivity_check[:response_timeout]
    end

    def configure_inactivity_check(connection, inactivity_check)
      connection.configure_inactivity_check(inactivity_check[:trigger_secs], inactivity_check[:response_timeout])
    end

    def get_current_time
      (Time.now.to_f * 1000).to_i
    end

    def gc
      timeout = @server.timeout
      return unless Numeric === timeout

      with_lock 'gc' do |release_lock|
        cutoff = get_current_time - 1000 * 2 * timeout
        redis.zrangebyscore(@ns + '/clients', 0, cutoff) do |clients|
          i, n = 0, clients.size
          next release_lock.call if i == n

          clients.each do |client_id|
            destroy_client(client_id) do
              i += 1
              release_lock.call if i == n
            end
          end
        end
      end
    end

    def with_lock(lock_name, &block)
      lock_key     = @ns + '/locks/' + lock_name
      current_time = get_current_time
      expiry       = current_time + LOCK_TIMEOUT * 1000 + 1

      release_lock = lambda do
        redis.del(lock_key) if get_current_time < expiry
      end

      redis.setnx(lock_key, expiry) do |set|
        next block.call(release_lock) if set == 1

        redis.get(lock_key) do |timeout|
          next unless timeout

          lock_timeout = timeout.to_i(10)
          next if current_time < lock_timeout

          redis.getset(lock_key, expiry) do |old_value|
            block.call(release_lock) if old_value == timeout
          end
        end
      end
    end

  end
end
