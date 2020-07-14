#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler'
Bundler.require(:default, ENV['RACK_ENV'] || 'development')

require 'fileutils'
require 'net/http'

$red, $green, $blue, $yellow, $reset = "\e[1;31m", "\e[1;32m", "\e[1;34m", "\e[1;33m", "\e[0;0m"

def msg(message, color = $reset)
  puts("#{color}#{message}#{$reset}")
  yield if block_given?
end

root = File.expand_path(__dir__)

if File.exist?("#{root}/tmp/dl.html")
  msg("Using cache: #{root}/tmp/dl.html", $yellow)
  body = File.read("#{root}/tmp/dl.html")
else
  msg("Fetching https://golang.org/dl/", $green)
  body = Net::HTTP.get(URI.parse('https://golang.org/dl/'))
end

doc = Nokogiri::HTML(body)

new_versions = doc.xpath('//a[starts-with(@href, "/dl/")]/parent::td/parent::tr').to_a

new_versions.map! do |tr|
  url = tr.xpath('./td/a').first.attribute('href').value
  next unless url

  match = url.scan(%r{ ^/dl/go(\d+\.\d+(?:\.\d+)?)\.(\w+)-(\w+).tar.gz }x)
  next unless match

  url = "https://golang.org#{url}"

  ver, os, arch = match.first
  next unless ver
  next unless os
  next unless arch

  arch = 'i686' if arch == '386'
  arch = 'x86_64' if arch == 'amd64'

  checksum = tr.xpath('./td/tt/text()').first.to_s
  next unless checksum

  {
    ver:      ver,
    os:       os,
    arch:     arch,
    url:      url,
    checksum: checksum,
  }
end
new_versions.reject!(&:nil?)

new_versions.reject! { |new_version| new_version[:url].include?('-bootstrap-') }
new_versions.reject! { |new_version| new_version[:url].include?('.windows-') }
new_versions.reject! { |new_version| new_version[:url].end_with?('.msi') }
new_versions.reject! { |new_version| new_version[:url].end_with?('.pkg') }
new_versions.reject! { |new_version| new_version[:url].end_with?('.src.tar.gz') }
new_versions.uniq! { |new_version| new_version[:url] }
new_versions.sort_by! { |new_version| Gem::Version.new(new_version[:ver]) }

old_versions = Dir.glob("#{root}/db/*/*/*/")
old_versions.map! do |dir|
  {
    ver:      File.basename(File.dirname(File.dirname(dir))),
    os:       File.basename(File.dirname(dir)),
    arch:     File.basename(dir),
    url:      File.read("#{dir}/url"),
    checksum: File.read("#{dir}/checksum"),
  }
end
old_versions.sort_by! { |old_version| Gem::Version.new(old_version[:ver]) }

msg('Removing old versions ...', $red) { FileUtils.rm_rf("#{root}/db") }

new_versions.each do |new_version|
  existing = old_versions.find do |old_version|
    old_version[:ver] == new_version[:ver] &&
      old_version[:os] == new_version[:os] &&
      old_version[:arch] == new_version[:arch]
  end
  same = old_versions.find do |old_version|
    old_version[:ver] == new_version[:ver] &&
      old_version[:os] == new_version[:os] &&
      old_version[:arch] == new_version[:arch] &&
      old_version[:url] == new_version[:url] &&
      old_version[:checksum] == new_version[:checksum]
  end

  old_versions.delete_if do |old_version|
    old_version[:ver] == new_version[:ver] &&
      old_version[:os] == new_version[:os] &&
      old_version[:arch] == new_version[:arch]
  end

  message, color = if same
    ["Keep    #{new_version[:ver]}/#{new_version[:os]}/#{new_version[:arch]}", $reset]
  elsif existing
    ["Freshen #{new_version[:ver]}/#{new_version[:os]}/#{new_version[:arch]}", $yellow]
  else
    ["Create  #{new_version[:ver]}/#{new_version[:os]}/#{new_version[:arch]}", $green]
  end

  msg(message, color) do
    FileUtils.mkdir_p("#{root}/db/#{new_version[:ver]}/#{new_version[:os]}/#{new_version[:arch]}")
    File.write("#{root}/db/#{new_version[:ver]}/#{new_version[:os]}/#{new_version[:arch]}/url", new_version[:url])
    File.write("#{root}/db/#{new_version[:ver]}/#{new_version[:os]}/#{new_version[:arch]}/checksum", new_version[:checksum])
  end
end

old_versions.each do |old_version|
  msg("Delete  #{old_version[:ver]}/#{old_version[:os]}/#{old_version[:arch]}", $red)
end
