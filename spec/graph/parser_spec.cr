require "../spec_helper"

describe Chiasmus::Graph::Parser do
  describe ".supported_extensions" do
    it "returns supported file extensions" do
      extensions = Chiasmus::Graph::Parser.supported_extensions
      extensions.should_not be_empty
      extensions.should contain(".py")
      extensions.should contain(".cr")
      extensions.should contain(".rs")
      extensions.should contain(".html")
    end
  end

  describe ".supported_languages" do
    it "returns supported language names" do
      languages = Chiasmus::Graph::Parser.supported_languages
      languages.should_not be_empty
      languages.should contain("python")
      languages.should contain("crystal")
    end
  end

  describe ".get_language_for_file" do
    it "maps .py extension to python" do
      lang = Chiasmus::Graph::Parser.get_language_for_file("script.py")
      lang.should eq("python")
    end

    it "maps .cr extension to crystal" do
      lang = Chiasmus::Graph::Parser.get_language_for_file("app.cr")
      lang.should eq("crystal")
    end

    it "returns nil for unsupported extension" do
      lang = Chiasmus::Graph::Parser.get_language_for_file("data.unknown")
      lang.should be_nil
    end
  end

  describe ".reset_service" do
    it "creates a new service instance" do
      original_extensions = Chiasmus::Graph::Parser.supported_extensions
      Chiasmus::Graph::Parser.reset_service
      new_extensions = Chiasmus::Graph::Parser.supported_extensions
      new_extensions.size.should eq(original_extensions.size)
    end
  end

  describe ".shutdown" do
    it "does not raise" do
      Chiasmus::Graph::Parser.shutdown
    end
  end
end
