# coding: utf-8
module FacebookIrcGateway
  class Channel

    OBJECTS = [
      'friends',
      'likes',
      'movies',
      'music',
      'books',
      'notes',
      'photos',
      'albums',
      'videos',
      'events',
      'groups',
      'checkins'
    ]

    attr_reader :server, :session, :name, :object

    def initialize(server, session, name)
      @server = server
      @session = session
      @name = name
      @object = nil
    end

    # IRC methods {{{1
    def send_irc_command(command, options = {})
      from = (options[:from] || @server.server_name).gsub(/\s+/, '')
      channel = options[:channel] || @name
      params = options[:params] || []
      @server.post from, command, channel, *params
    end

    def privmsg(message, options = {})
      send_irc_command 'PRIVMSG', options.merge(:params => [message])
    end

    def notice(message, options = {})
      send_irc_command 'NOTICE', options.merge(:params => [message])
    end
    #}}}

    # Events {{{1
    def on_privmsg(message)
      # check command
      return if process_command message
      return if @session.command_manager.process self, message
      if has_object?
        status = update message
      end
    end

    def on_join
    end

    def on_part
      stop
    end

    def on_topic(topic)
      #start topic
    end
    # }}}

    def has_object?
      not @object.nil?
    end

    def object_name(item)
      item.inject([]) do |result, (key, value)|
        result << value if ['name', 'category'].include? key; result
      end.join(' / ')
    end
    # }}}

    def start(id)
      @object = FacebookOAuth::FacebookObject.new(id, @session.api)
      @duplications = Duplication.objects(id)

      notice "start: #{object_name @object.info} (#{id})"

      stop
      @check_feed_thread = async do
        check_feed
      end
    end

    def stop
      if @check_feed_thread
        @check_feed_thread.exit
        @check_feed_thread.join
        @check_feed_thread = nil
      end
    end

    def feed
      Feed.new(@object.feed,@session.user_filter)
    end

    def update(message)
      status = @object.feed(:create, :message => message)
      @session.history << {:id => status['id'], :type => :status, :message => message} if status
    end

    private

    def async(options = {})
      @server.log.debug 'begin: async'
      count = options[:count] || 0
      interval = options[:interval] || 30

      return Thread.start do
        loop do
          if count > 0
            count -= 1
            break if count == 0
          end

          begin
            yield
          rescue Exception => e
            error_messages(e)
          end

          sleep interval
        end
        @server.log.debug 'end: async'
      end
    end

    def check_duplication(id)
      dup = @duplications.find_or_initialize_by_object_id(id)
      new = dup.new_record?
      dup.save
      yield if new
    end

    def check_feed
      #@server.log.debug 'begin: check_feed'
      feed.reverse.each do |item|
        send_message item
      end
      #@server.log.debug 'end: check_feed'
    end

    def send_message(item, options = {})
      begin
        check_duplication item.id do
          tid = @session.typablemap.push(item)
          # TODO: auto-liker
          #@client.status(item.id).likes(:create) if @opts.autoliker == true
          method = (item.from.id == @session.me['id']) ? :notice : :privmsg
          send method, item.to_s(:tid => tid, :color => @session.options.color), :from => item.from.nick
        end

        item.comments.each do |comment|
          check_duplication comment.id do
            unless @session.user_filter.get_invisible( :type => :comment , :id => coment.parent.from.id )
              ctid = @session.typablemap.push(comment)
              method = (comment.from.id == @session.me['id']) ? :notice : :privmsg
              send method, comment.to_s(:tid => ctid, :color => @session.options.color), :from => comment.from.nick
            end
          end
        end

        item.likes.each do |like|
          lid = "#{item.id}_like_#{like.from.id}"
          check_duplication lid do
            unless @session.user_filter.get_invisible( :type => :like , :id => like.parent.from.id )
              notice like.to_s(:color => @session.options.color), :from => like.from.nick
            end
          end
        end if item.from.id == @session.me['id']

      rescue Exception => e
        error_messages(e)
      end
    end

    def process_command(message)
      command, args = message.split(/\s+/)
      return false if not OBJECTS.include?(command)

      @server.log.debug "command: #{[command, args].to_s}"

      items = @session.api.me.send(command)['data'].reverse
      @server.log.debug "items: #{items.to_s}"

      if items.empty?
        notice 'no match found'
      else
        if args.nil?
          # list show
          items.each_with_index do |item, index|
            notice "#{index + 1}: #{object_name item}"
          end
        else
          # set object
          item = items[args.to_i - 1]
          if item
            start item['id']
          else
            notice 'invalid argument'
          end
        end
      end

      return true
    end

    def error_messages(e)
      @server.error_messages e
    end
    
    def error_notice(e)
      @server.error_notice e
    end
  end

  class NewsFeedChannel < Channel
    def feed
      Feed.new(@object.home,@session.user_filter)
    end
  end

end

