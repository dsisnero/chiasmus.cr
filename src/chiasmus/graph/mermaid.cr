require "./facts"

module Chiasmus
  module Graph
    module Mermaid
      extend self

      enum DiagramType
        Flowchart
        StateDiagram
      end

      record MermaidNode,
        id : String,
        label : String? = nil

      record MermaidEdge,
        from : String,
        to : String,
        label : String? = nil

      record MermaidGraph,
        type : DiagramType,
        nodes : Hash(String, MermaidNode),
        edges : Array(MermaidEdge)

      FLOWCHART_RULES = <<-PROLOG.strip
        % Cycle-safe reachability for flowcharts
        member(X, [X|_]).
        member(X, [_|T]) :- member(X, T).
        reaches(A, B) :- reaches(A, B, [A]).
        reaches(A, B, _) :- edge(A, B).
        reaches(A, B, Visited) :- edge(A, Mid), \\+ member(Mid, Visited), reaches(Mid, B, [Mid|Visited]).
      PROLOG

      STATE_RULES = <<-PROLOG.strip
        % Cycle-safe reachability for state diagrams
        member(X, [X|_]).
        member(X, [_|T]) :- member(X, T).
        can_reach(A, B) :- can_reach(A, B, [A]).
        can_reach(A, B, _) :- transition(A, B, _).
        can_reach(A, B, Visited) :- transition(A, Mid, _), \\+ member(Mid, Visited), can_reach(Mid, B, [Mid|Visited]).
      PROLOG

      def parse(input : String) : String
        generate_prolog(extract_graph(input))
      end

      def normalize_id(id : String) : String
        return "start_end" if id == "[*]"

        normalized = id.downcase.gsub(/[^a-z0-9_]/, "_").gsub(/_+/, "_").gsub(/^_+|_+$/, "")
        normalized.empty? ? "node" : normalized
      end

      def extract_graph(input : String) : MermaidGraph
        lines = input.lines.map(&.strip)
        type = detect_diagram_type(lines)
        nodes = {} of String => MermaidNode
        edges = [] of MermaidEdge

        lines.each do |line|
          next if skip_line?(line)

          if type.state_diagram?
            parse_state_line(line, nodes, edges)
          else
            parse_flowchart_line(line, nodes, edges)
          end
        end

        MermaidGraph.new(type: type, nodes: nodes, edges: edges)
      end

      def detect_diagram_type(lines : Enumerable(String)) : DiagramType
        lines.each do |line|
          return DiagramType::StateDiagram if line.matches?(/^stateDiagram/i)
          return DiagramType::Flowchart if line.matches?(/^(graph|flowchart)\b/i)
        end

        DiagramType::Flowchart
      end

      def extract_label(raw : String?) : String?
        return nil unless raw

        match = raw.strip.match(/^[\[({]+\s*(.*?)\s*[\])}]+$/)
        match.try(&.[1]?).presence
      end

      def parse_flowchart_line(line : String, nodes : Hash(String, MermaidNode), edges : Array(MermaidEdge)) : Nil
        pattern = /^([A-Za-z0-9_]+)(\s*[\[({].*?[\])}])?\s*([-=][-=.]+[>ox]?)\s*(?:\|([^|]*)\|)?\s*([A-Za-z0-9_]+)(\s*[\[({].*?[\])}])?\s*;?\s*$/
        match = line.match(pattern)
        return unless match

        src_id = match[1]
        src_label = match[2]?
        edge_label = match[4]?
        tgt_id = match[5]
        tgt_label = match[6]?

        src_norm = normalize_id(src_id)
        tgt_norm = normalize_id(tgt_id)

        register_node(nodes, src_norm, extract_label(src_label))
        register_node(nodes, tgt_norm, extract_label(tgt_label))

        edges << MermaidEdge.new(from: src_norm, to: tgt_norm, label: edge_label.try(&.strip))
      end

      def parse_state_line(line : String, nodes : Hash(String, MermaidNode), edges : Array(MermaidEdge)) : Nil
        match = line.match(/^(\[\*\]|[A-Za-z0-9_]+)\s*-->\s*(\[\*\]|[A-Za-z0-9_]+)\s*(?::\s*(.+))?$/)
        return unless match

        src_norm = normalize_id(match[1])
        tgt_norm = normalize_id(match[2])
        event = match[3]?.try(&.strip)

        nodes[src_norm] ||= MermaidNode.new(id: src_norm)
        nodes[tgt_norm] ||= MermaidNode.new(id: tgt_norm)
        edges << MermaidEdge.new(from: src_norm, to: tgt_norm, label: event)
      end

      def generate_prolog(graph : MermaidGraph) : String
        graph.type.state_diagram? ? generate_state_prolog(graph) : generate_flowchart_prolog(graph)
      end

      private def skip_line?(line : String) : Bool
        line.empty? ||
          line.starts_with?("%%") ||
          line.matches?(/^(graph|flowchart|stateDiagram)\b/i) ||
          line == "end" ||
          line.matches?(/^subgraph\b/i)
      end

      private def register_node(nodes : Hash(String, MermaidNode), id : String, label : String?) : Nil
        existing = nodes[id]?
        if existing
          if label && existing.label.nil?
            nodes[id] = MermaidNode.new(id: existing.id, label: label)
          end
        else
          nodes[id] = MermaidNode.new(id: id, label: label)
        end
      end

      private def generate_state_prolog(graph : MermaidGraph) : String
        lines = [] of String
        lines << ":- dynamic(transition/3)."
        lines << ":- dynamic(state/1)."
        lines << ""

        graph.nodes.each_value do |node|
          lines << "state(#{Facts.escape_atom(node.id)})."
        end
        lines << "" unless graph.nodes.empty?

        graph.edges.each do |edge|
          event = edge.label || "auto"
          lines << "transition(#{Facts.escape_atom(edge.from)}, #{Facts.escape_atom(edge.to)}, #{Facts.escape_atom(event)})."
        end
        lines << ""
        lines << STATE_RULES
        lines.join("\n")
      end

      private def generate_flowchart_prolog(graph : MermaidGraph) : String
        lines = [] of String
        lines << ":- dynamic(node/2)."
        lines << ":- dynamic(edge/2)."
        lines << ":- dynamic(edge_label/3)."
        lines << ""

        graph.nodes.each_value do |node|
          label = node.label || node.id
          lines << "node(#{Facts.escape_atom(node.id)}, #{Facts.escape_atom(label)})."
        end
        lines << "" unless graph.nodes.empty?

        graph.edges.each do |edge|
          lines << "edge(#{Facts.escape_atom(edge.from)}, #{Facts.escape_atom(edge.to)})."
        end

        labeled_edges = graph.edges.select { |edge| !edge.label.nil? }
        unless labeled_edges.empty?
          lines << ""
          labeled_edges.each do |edge|
            label = edge.label || ""
            lines << "edge_label(#{Facts.escape_atom(edge.from)}, #{Facts.escape_atom(edge.to)}, #{Facts.escape_atom(label)})."
          end
        end

        lines << ""
        lines << FLOWCHART_RULES
        lines.join("\n")
      end
    end
  end
end
