#!/usr/bin/env ruby
require "rubygems"
require "bundler/setup"

# get all the gems in
Bundler.require(:default)

Daemons.run('glaucus.rb')