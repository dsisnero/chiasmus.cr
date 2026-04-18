require "spec"
require "../src/chiasmus"

# Helper to temporarily set environment variables for tests
def with_env(env_vars : Hash(String, String?), &)
  original_values = {} of String => String?

  env_vars.each do |key, value|
    original_values[key] = ENV[key]?
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  begin
    yield
  ensure
    original_values.each do |key, original_value|
      if original_value.nil?
        ENV.delete(key)
      else
        ENV[key] = original_value
      end
    end
  end
end
