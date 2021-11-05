# frozen_string_literal: true

require 'uri'
require 'time'
require 'rss'
require 'base64'
require 'zlib'
require 'sqlite3'
require 'nokogiri'
require 'logger'
require 'json'
require 'fileutils'

#
# Feed bloater.
#
module FeedBloater
  #
  # Base config class.
  #
  class Config
    attr :db_path,      # cache db path
         :rss_url,      # rss URL
         :css_selector, # css selector
         :dst_path,     # destination path
         :user_agent,   # user agent (defaults to "feedbloater/0.1")
         :log_path,     # log path (defaults to "STDERR")
         :log_level,    # log level (defaults to "info")
         :log,          # logger instance
         :num_items,    # number of items to fetch
         :write_mode,   # one of "always" or "changed"
         :feed_title,   # feed title override
         :feed_link     # feed link override
  end

  #
  # Thin SQLite3 database wrapper with logging.
  #
  class LoggingDB < ::SQLite3::Database
    attr :log

    #
    # Create instance from path and logger
    #
    def initialize(db_path, log)
      super(db_path)
      @log = log
    end

    #
    # log and execute query
    #
    def execute(sql, *args)
      # log query and args
      @log.debug('execute') do
        JSON({ sql: sql, args: args })
      end

      # exec query
      super(sql, *args)
    end
  end

  #
  # SQLite3-backed URL cache
  #
  class Cache < LoggingDB
    SQL = {
      create_table: %{
        CREATE TABLE urls (
          url             TEXT UNIQUE NOT NULL PRIMARY KEY,
          etag            TEXT NOT NULL,
          last_modified   TEXT NOT NULL,
          body            TEXT NOT NULL
        );
      },

      delete_url: %{
        DELETE FROM urls WHERE url = ?
      },

      insert_url: %{
        INSERT INTO urls(url, etag, last_modified, body) VALUES (?, ?, ?, ?)
      },

      get_body: %{
        SELECT body
          FROM urls
         WHERE url = ?
      },

      get_headers: %{
        SELECT etag,
               last_modified
          FROM urls
         WHERE url = ?
      },
    }.each.with_object({}) do |p, r|
      r[p[0]] = p[1].strip
    end.freeze

    def initialize(db_path, user_agent, log)
      # create destination directory if it does not exist
      dir_path = File.dirname(db_path)
      FileUtils.mkdir_p(dir_path) unless Dir.exists?(dir_path)

      # init superclass, cache user_agent
      super(db_path, log)
      @user_agent = user_agent

      # create urls table (if necessary)
      execute(SQL[:create_table]) unless table_info('urls').size > 0
    end

    #
    # Get URL body.
    #
    # Returns an array where the first entry is the URL body and the
    # second entry is a boolean indicating whether the results are new
    # or not.
    #
    def [](url)
      begin
        @log.debug('Cache#[]') { "fetching #{url}" }
        URI.parse(url).open(get_headers(url)) do |fh|
          @log.debug('Cache#[]') { "updating cache for #{url}" }
          # read body
          body = fh.read

          # get headers
          etag = fh.metas.fetch('etag', ['']).first
          last_modified = fh.metas.fetch('last-modified', ['']).first

          # update cache
          update_url(url, etag, last_modified, body)

          # return body
          [body, true]
        end
      rescue ::OpenURI::HTTPError => e
        if e.message =~ /304 not modified/i
          # return cached result
          @log.debug('Cache#[]') { "got 304 for #{url}" }
          [get_body(url), false]
        else
          # raise error
          raise e
        end
      end
    end

    private

    #
    # Update URL in cache.
    #
    def update_url(url, etag, last_modified, body)
      transaction do
        @log.debug('Cache#update_url') { "update #{url}" }
        delete_url(url)
        insert_url(url, etag, last_modified, body)
      end

      nil
    end

    #
    # Delete URL from cache.
    #
    def delete_url(url)
      execute(SQL[:delete_url], [url])
      nil
    end

    #
    # Add URL to cache.
    #
    def insert_url(url, etag, last_modified, body)
      # compress and base64-encode body
      body = Base64.encode64(Zlib::Deflate.deflate(body))
      execute(SQL[:insert_url], [url, etag, last_modified, body])
      nil
    end

    #
    # Get body for given URL.
    #
    def get_body(url)
      execute(SQL[:get_body], [url]) do |row|
        # base64-decode and inflate body
        return Zlib::Inflate.inflate(Base64.decode64(row.first))
      end

      raise "Unknown URL"
    end

    #
    # Get request headers for given URL.
    #
    def get_headers(url)
      headers = {}

      execute(SQL[:get_headers], [url]) do |row|
        # build headers from row
        headers = {
          'user-agent' => @user_agent,
        }

        %w{if-none-match if-modified-since}.each_with_index do |k, i|
          headers[k] = row[i] if row[i].match(/\S/)
        end
      end

      # return result
      headers
    end
  end

  #
  # RSS feed element.
  #
  class Item
    attr_reader :name, :link, :time

    #
    # Build feed item from <item> in RSS feed.
    #
    def initialize(el)
      @name = (el / 'title').text
      @link = (el / 'link').text
      @time = Time.parse((el / 'pubDate').text)
    end
  end

  #
  # RSS feed object.
  #
  class Feed
    attr_reader :title, :description, :link, :items

    #
    # Parse feed at given URL.
    #
    def initialize(cache, url)
      # read body from cache, parse document
      body, @changed = cache[url]
      doc = Nokogiri::XML(body)

      # extract feed attributes
      @title = (doc / 'channel / title').text
      @link = (doc / 'channel / link').text
      @description = (doc / 'channel / description').text

      # parse feed items
      @items = (doc / 'item').map { |e| Item.new(e) }
    end

    #
    # Returns true if this feed has changed, and false otherwise
    #
    def changed?
      @changed
    end
  end

  #
  # RSS feed builder.
  #
  class Builder
    #
    # Create feed builder instance.
    #
    def initialize(cache)
      @cache = cache
    end

    #
    # Build RSS feed and return the result as a string.
    #
    def build(feed, config)
      io = StringIO.new
      io << RSS::Maker.make('2.0') do |m|
        m.channel.author = ''
        m.channel.title = config.feed_title || feed.title
        m.channel.description = feed.description
        m.channel.link = config.feed_link || feed.link

        # add items
        feed.items.take(config.num_items).each do |src_item|
          # parse full body
          full_body, changed = @cache[src_item.link]

          # get post body
          body = (Nokogiri::HTML(full_body) / config.css_selector).inner_html

          # add item to output feed
          m.items.new_item do |dst_item|
            # build item
            dst_item.title = src_item.name
            dst_item.link = src_item.link
            dst_item.updated = src_item.time
            dst_item.description = body
          end
        end
      end

      # return string
      io.string
    end
  end

  #
  # Command-line interface.
  #
  module CLI
    #
    # Build config from CLI args and environment.
    #
    class Config < ::FeedBloater::Config
      DEFAULT_CACHE_PATH = File.expand_path('~/.config/feedbloater/cache.db')

      DEFAULT_USER_AGENT = 'feedbloater/0.1'

      #
      # Build config from CLI args and environment.
      #
      def initialize(app, args, env)
        # get config from environment
        @db_path = env.fetch('FEEDBLOATER_CACHE_PATH', DEFAULT_CACHE_PATH)
        @user_agent = env.fetch('FEEDBLOATER_USER_AGENT', DEFAULT_USER_AGENT)
        @num_items = env.fetch('FEEDBLOATER_NUM_ITEMS', '20').to_i
        @write_mode = env.fetch('FEEDBLOATER_WRITE_MODE', 'changed').intern
        @feed_title = env.fetch('FEEDBLOATER_FEED_TITLE', nil)
        @feed_link = env.fetch('FEEDBLOATER_FEED_LINK', nil)

        # check cli args
        unless args.size == 3
          raise "Usage #$0 rss_url css_selector rss_path"
        end

        # get args
        @rss_url, @css_selector, @dst_path = args

        # get log path and level
        @log_path = env.fetch('FEEDBLOATER_LOG_PATH', 'STDERR')
        @log_level = env.fetch('FEEDBLOATER_LOG_LEVEL', 'info')

        # create/cache logger
        @log = ::Logger.new((@log_path == 'STDERR') ? STDERR : @log_path)
        @log.level = @log_level
      end
    end

    #
    # Command-line entry point
    #
    def self.run(app, args, env)
      # build config
      config = Config.new(app, args, env)

      begin
        # create cache and feed
        cache = Cache.new(config.db_path, config.user_agent, config.log)
        feed = Feed.new(cache, config.rss_url)

        # write feed file if feed has changed
        if (config.write_mode == :always) || feed.changed?
          # create feed builder
          builder = Builder.new(cache)

          # build rss
          rss = builder.build(feed, config)

          # write RSS to file
          config.log.debug('run') do
            "writing #{rss.size} bytes to #{config.dst_path}"
          end
          File.write(config.dst_path, rss)
        end
      rescue Exception => e
        config.log.fatal('run') { e }
        raise e
      end
    end
  end
end
