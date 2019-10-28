#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler'
Bundler.require(:default, ENV['RACK_ENV'] || 'development')

require 'fileutils'
require 'net/http'

root = File.expand_path(__dir__)

if File.exist?("#{root}/tmp/dl.html")
  body = File.read("#{root}/tmp/dl.html")
else
  body = Net::HTTP.get(URI.parse('https://golang.org/dl/'))
end

doc = Nokogiri::HTML(body)

versions = doc.xpath('//a[starts-with(@href, "https://dl.google.com/go/")]/parent::td/parent::tr').to_a
versions.map! do |tr|
  url = tr.xpath('./td/a').first.attribute('href').value
  next unless url

  checksum = tr.xpath('./td/tt/text()').first.to_s
  next unless checksum

  {
    url:      url,
    checksum: checksum,
  }
end

versions.reject! { |version| version[:url].include?('-bootstrap-') }
versions.reject! { |version| version[:url].include?('.windows-') }
versions.reject! { |version| version[:url].end_with?('.msi') }
versions.reject! { |version| version[:url].end_with?('.pkg') }
versions.reject! { |version| version[:url].end_with?('.src.tar.gz') }
versions.uniq! { |version| version[:url] }

FileUtils.rm_rf("#{root}/db")

versions.each do |version|
  # https://dl.google.com/go/go1.13.3.linux-amd64.tar.gz
  match = version[:url].scan(%r{ ^https://dl.google.com/go/go(\d+\.\d+(?:\.\d+)?)\.(\w+)-(\w+).tar.gz$ }x)
  next unless match

  ver, os, arch = match.first
  next unless ver
  next unless os
  next unless arch

  arch = 'i686' if arch == '386'
  arch = 'x86_64' if arch == 'amd64'

  FileUtils.mkdir_p("#{root}/db/#{ver}/#{os}/#{arch}")
  File.write("#{root}/db/#{ver}/#{os}/#{arch}/url", version[:url])
  File.write("#{root}/db/#{ver}/#{os}/#{arch}/checksum", version[:checksum])
end
