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

#
# Feed bloater.
#
module FeedBloater
  class LoggingDB < ::SQLite3::Database
    def initialize(db_path, logger)
      super(db_path)
      @logger = logger
    end

    def execute(sql, *args)
      # log query and args
      @logger.debug('execute') do
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
  
    def initialize(db_path, logger)
      super(db_path, logger)
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
        URI.parse(url).open(get_headers(url)) do |fh|
          # read body
          body = fh.read
  
          # update cache
          transaction do
            delete_url(url)
            insert_url(url, fh.metas['etag'].first, fh.metas['last-modified'].first, body)
          end
  
          # return body
          [body, true]
        end
      rescue ::OpenURI::HTTPError => e
        if e.message =~ /304 not modified/i
          [get_body(url), false]
        else
          raise e
        end
      end
    end
  
    private
  
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
          'if-none-match' => row[0],
          'if-modified-since' => row[1],
        }
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
    def initialize(cache, num_items = 20)
      @cache = cache
      @num_items = num_items
    end
  
    #
    # Build RSS feed and return the result as a string.
    #
    def self.build(feed, css_selector)
      RSS::Maker.make('2.0') do |m|
        m.channel.author = ''
        m.channel.title = feed.title
        m.channel.description = feed.description
        m.channel.link =  feed.link
      
        # add items
        feed.items.take(@num_items).each do |src_item|
          # parse full body
          full_body, changed = @cache[src_item.link]
  
          # get post body
          body = (Nokogiri::HTML(full_body) / css_selector).inner_html
  
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
    end
  end

  #
  # Command-line entry point
  #
  def self.run(app, args)
    raise "Usage #$0 db_path rss_path" unless args.size == 2
    db_path = args[0]
    dst_path = args[1]

    # build logger
    logger = ::Logger.new(STDERR)
    logger.level = 'debug'
    
    # create cache and feed
    cache = Cache.new(db_path, logger)
    feed = Feed.new(cache, 'https://llvmweekly.org/rss.xml')
    
    # write feed file if feed has changed
    if feed.changed?
      # create feed builder
      builder = Builder.new(cache)

      # build rss
      rss = builder.build(feed, 'div.post')

      # write RSS to file
      logger.debug('run') { "writing #{rss.size} bytes to #{dst_path}" }
      File.write(dst_path, rss)
    end
  end
end
