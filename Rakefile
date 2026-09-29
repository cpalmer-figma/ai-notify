require "rake/testtask"

# `bundle exec rake test` (or just `bundle exec rake`) runs every test/*_test.rb.
Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test
