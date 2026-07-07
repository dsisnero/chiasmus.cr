require "../spec_helper"
require "file_utils"
require "tree-sitter-manager"

describe "Chiasmus MCP tool cancellation" do
  it "returns a cancellation response without waiting for blocked tool work to finish" do
    tmpdir = ""
    begin
      tmpdir = File.join(Dir.tempdir, "chiasmus-tool-cancel-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      path = File.join(tmpdir, "f.ts")
      File.write(path, "export function f() {}")
      entered = Channel(Bool).new(1)
      release = Channel(Bool).new(1)

      Chiasmus::Graph::Extractor.set_before_async_result_send_hook_for_test do
        entered.send(true)
        release.receive?
      end

      with_env({
        "CHIASMUS_EMBED_PROVIDER" => "ollama",
        "CHIASMUS_EMBED_MODEL"    => nil,
        "CHIASMUS_EMBED_URL"      => nil,
        "OPENAI_API_KEY"          => nil,
        "DEEPSEEK_API_KEY"        => nil,
      }) do
        server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
        transport = server.build_mcp_transport

        client_transport, server_transport = MCP::Shared::InMemoryTransport.create_linked_pair
        responses = Channel(MCP::Protocol::JSONRPCMessage).new(5)
        client_transport.on_message { |message| responses.send(message) }
        transport.connect(server_transport)

        begin
          request = MCP::Protocol::CallToolRequest.new(
            name: "chiasmus_search",
            arguments: {
              "query" => JSON::Any.new("find function"),
              "files" => JSON.parse([path].to_json),
            }
          )

          spawn do
            client_transport.send(request)
          end
          TreeSitterManager::Timeout.with_timeout_async(500, entered).should eq(true)

          request_id = request.id || raise "expected cancellable request id"
          client_transport.send(MCP::Protocol::CancelledNotification.new(request_id: request_id))

          message = TreeSitterManager::Timeout.with_timeout_async(500, responses)
          message.should be_a(MCP::Protocol::JSONRPCResponse)

          response = message.as(MCP::Protocol::JSONRPCResponse)
          result = response.result.as(MCP::Protocol::CallToolResult)
          payload = JSON.parse(result.content.first.as(MCP::Protocol::TextContentBlock).text)
          payload["status"].as_s.should eq("error")
          payload["error"].as_s.downcase.should contain("cancel")
        ensure
          release.send(true) rescue nil
          transport.close rescue nil
          server.skill_library.close rescue nil
        end
      end
    ensure
      Chiasmus::Graph::Extractor.clear_before_async_result_send_hook_for_test
      FileUtils.rm_rf(tmpdir) unless tmpdir.empty?
    end
  end
end
