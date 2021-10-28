#!/usr/bin/env ruby
# frozen_string_literal: true

require 'sqlite3'
require 'nokogiri'
require 'uri'
require 'time'
require 'rss'

#
# SQLite3-backed URL cache
#
class Cache < SQLite3::Database
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
  }

  def initialize(db_path)
    super(db_path)
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
    execute(SQL[:insert_url], [url, etag, last_modified, body])
    nil
  end

  #
  # Get body for given URL.
  #
  def get_body(url)
    execute(SQL[:get_body], [url]) do |row|
      return row.first
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

class FeedItem
  attr_reader :name, :link, :time

  #
  # Build feed item from <item> element.
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
  def initialize(cache, url = 'https://llvmweekly.org/rss.xml')
    # read body from cache, parse document
    body, @changed = cache[url]
    doc = Nokogiri::XML(body)

    # extract feed attributes
    @title = (doc / 'channel / title').text
    @link = (doc / 'channel / link').text
    @description = (doc / 'channel / description').text

    # parse feed items
    @items = (doc / 'item').map { |e| FeedItem.new(e) }
  end

  #
  # Returns true if this feed has changed, and false otherwise
  #
  def changed?
    @changed
  end
end

module FeedWriter
  NUM_ITEMS = 20

  #
  # Write feed to given file.
  #
  def self.write(path, cache, feed)
    File.write(path, RSS::Maker.make('2.0') do |m|
      m.channel.author = ''
      m.channel.title = feed.title
      m.channel.description = feed.description
      m.channel.link =  feed.link
    
      # add items
      feed.items.take(NUM_ITEMS).each do |feed_item|
        # parse full body
        full_body, changed = cache[feed_item.link]

        # get post body
        body = (Nokogiri::HTML(full_body) / 'div.post').inner_html

        # add rss item
        m.items.new_item do |item|
          # build item
          item.title = feed_item.name
          item.link = feed_item.link
          item.updated = feed_item.time
          item.description = body
        end
      end
    end)
  end
end

raise "Usage #$0 db_path rss_path" unless ARGV.size == 2
db_path = ARGV[0]
dst_path = ARGV[1]

# create cache and feed
cache = Cache.new(db_path)
feed = Feed.new(cache)

# write feed file if feed has changed
FeedWriter.write(dst_path, cache, feed) if feed.changed?

# feed.items.take(20).each do |item|
#   headers = if row = cache.get_post_headers(item.link)
#     { 'if-none-match' => row['etag'], 'if-modified-since' => row['last_modified'] }
#   else
#     {}
#   end
# 
#   body = Nokogiri::HTML(URI.parse(item.link).open(headers).open do |fh|
#     
#     html = Nokogiri::HTML(URI.parse(item.link).open({ 'if-non-match' => "W/\"6151d598-2ca5\"", 'if-modified-sinc
#     Body.new(item.link, fh.metas['etag'], fh.metas['last-modified'], fh.puts %w{etag last-modified}
# .each.with_object({}) { |k, r| r[k] = fh.metas[k].first }; fh.read }) / 'div.pos
# 
#   
# 
# data = URI.parse('https://llvmweekly.org/rss.xml').open.read
# doc = Nokogiri::XML(data)
# 
# (doc / 'item').map { |item| { name: (item / 'title').text, link: (item / 'link').text, date: Time.parse((item / 'pubDate').text) } }
# 
# post = (Nokogiri::HTML(URI.parse('https://llvmweekly.org/issue/11').open({ 'if-non-match' => "W/\"6151d598-2ca5\"", 'if-modified-sinc
# e' => "Mon, 27 Sep 2021 14:30:48 GMT" }).open { |fh| puts %w{etag last-modified}
# .each.with_object({}) { |k, r| r[k] = fh.metas[k].first }; fh.read }) / 'div.pos
# t').inner_html.trim
