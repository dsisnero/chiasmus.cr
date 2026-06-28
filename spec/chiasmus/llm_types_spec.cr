require "../spec_helper"

describe Chiasmus::LLM::SimpleConfig do
  it "defaults to deepseek provider and model when env is unset" do
    previous_provider = ENV["CHIASMUS_LLM_PROVIDER"]?
    previous_model = ENV["CHIASMUS_LLM_MODEL"]?
    ENV.delete("CHIASMUS_LLM_PROVIDER")
    ENV.delete("CHIASMUS_LLM_MODEL")

    config = Chiasmus::LLM::SimpleConfig.new
    config.provider.should eq("deepseek")
    config.model.should eq(Chiasmus::LLM::DEFAULT_MODEL)
  ensure
    previous_provider ? (ENV["CHIASMUS_LLM_PROVIDER"] = previous_provider) : ENV.delete("CHIASMUS_LLM_PROVIDER")
    previous_model ? (ENV["CHIASMUS_LLM_MODEL"] = previous_model) : ENV.delete("CHIASMUS_LLM_MODEL")
  end

  it "infers the provider from a deepseek model name" do
    config = Chiasmus::LLM::SimpleConfig.new(provider: "", model: "deepseek-chat")
    config.provider.should eq("deepseek")
  end

  it "keeps an explicit provider even when the model name looks different" do
    config = Chiasmus::LLM::SimpleConfig.new(provider: "openai", model: "deepseek-chat")
    config.provider.should eq("openai")
  end
end
