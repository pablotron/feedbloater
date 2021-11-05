# Feed Bloater

Transform truncated [RSS 2.0][rss] feeds into full content feeds by
doing the following:

1. Fetch the contents of the feed.
2. Grab the [HTML][] from the `<link>` from each feed item.
3. Limit the [HTML][] from the previous step via a [CSS selector][css-selector]. 
4. Replace the description of each feed item with the [HTML][] from the previous step.
5. Write the result to the given path.

You can run Feed Bloater from a [cron job][cron] like so:

```
# fetch llvmweekly RSS feed hourly
@hourly bundle exec path/to/bin/feedbloater https://llvmweekly.org/rss.xml div.post path/to/llvmweekly.xml
```

## Installation

Run `bundle install` to install dependencies:

    # install dependencies
    $ bundle

## Usage

Execute `bundle exec bin/feedbloater` with the following parameters:

1. [RSS][] feed [URL][].
2. [CSS selector][css-selector].
3. Destination path.

Example:

```
# this command does the following:
#
# 1. Fetch the LLVM Weekly RSS feed.
# 2. Fetch the HTML for the 20 most recent feed items.
# 3. Filter the HTML of each feed item to the inner HTML of the
#    "div.post" element.
# 4. Replace the description of each item with the HTML from the
#    previous step.
# 5. Write the generated feed to `llvmweekly.xml`.
#
$ bundle exec bin/feedbloater https://llvmweekly.org/rss.xml div.post llvmweekly.xml
```

You can also control the execution via environment variables.  For
example, you can set the log level to `debug` like so:

```
$ FEEDBLOATER_LOG_LEVEL=debug bundle exec bin/feedbloater https://llvmweekly.org/rss.xml div.post llvmweekly.xml
```

See the **Environment Variables** section for a complete list of
available environment variables.

## Environment Variables

| Name | Description | Default Value |
|------|-------------|---------------|
|`FEEDBLOATER_CACHE_PATH`|Absolute path to cache [SQLite][]database.|`~/.config/feedbloater/cache.db`|
|`FEEDBLOATER_USER_AGENT`|Value of `User-Agent` header.|`feedbloater/0.1`|
|`FEEDBLOATER_NUM_ITEMS`|Number of items to fetch from source feed.|`20`|
|`FEEDBLOATER_WRITE_MODE`|Destination file write mode.  One of `always` or `changed`.|`changed`|
|`FEEDBLOATER_FEED_TITLE`|Destination file feed title override.|`n/a` (title copied from source feed)|
|`FEEDBLOATER_FEED_LINK`|Destination file feed link override.|`n/a` (link copied from source feed)|

[rss]: https://en.wikipedia.org/wiki/RSS
  "Really Simple Syndication"
[url]: https://en.wikipedia.org/wiki/URL
  "Uniform Resource Locator"
[html]: https://en.wikipedia.org/wiki/HTML
  "HyperText Markup Language"
[css-selector]: https://en.wikipedia.org/wiki/CSS#Selector
  "Cascading Style Sheet selector"
[cron]: https://en.wikipedia.org/wiki/Cron
  "Periodic task scheduler."
[sqlite]: https://sqlite.org/
  "SQLite database."
