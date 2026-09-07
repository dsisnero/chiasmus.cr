require "../../graph/extractor"
require "../../graph/parallel_io"
require "../../index/project_index"
require "../../utils/bounded_work"
require "tracing"

module Chiasmus
  module MCPServer
    module Tools
      module IndexedGraphLoader
        extend self

        def load_graph(
          paths : Array(String),
          cache_dir : String?,
          project_index : Index::ProjectIndex?,
          trace_event : String,
        ) : Graph::CodeGraph?
          if index = project_index
            lookup = index.lookup(paths)
            Tracing.info(trace_event, cache_status: lookup.status, files: paths.size)
            return lookup.graph if lookup.graph

            refreshed = refresh_indexed_paths(index, paths, cache_dir)
            return refreshed if refreshed
          end

          source_files = Graph::FileIO.read_source_files_or_raise(paths)
          Graph::Extractor.extract_graph_async(source_files, cache_dir: cache_dir, parallel_cpu: true).receive
        end

        private def refresh_indexed_paths(
          index : Index::ProjectIndex,
          paths : Array(String),
          cache_dir : String?,
        ) : Graph::CodeGraph?
          graphs = Utils::BoundedWork.map_ordered(paths) do |path|
            Graph::Extractor.extract_and_cache_file(path, cache_dir: cache_dir)
          end.compact_map(&.itself)

          index.upsert_files(graphs) unless graphs.empty?
          index.graph_for(paths)
        end
      end
    end
  end
end
