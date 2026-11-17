# frozen_string_literal: true

require "bundler/gem_tasks"

desc "Run the test suite"
task :test do
  ruby "-w", "-Ilib", "-Itest", "-e", "ARGV.each { |file| require File.expand_path(file) }",
       *FileList["test/**/*_test.rb"]
end

task default: :test
