import SwiftUI

/// Your friend map (friend-graph.md): you, your friends, who among them know
/// each other, and a "?" for each person a friend knows that you don't (no id,
/// no name: only ever what the server sends you). Laid out on the phone.
@MainActor @Observable final class FriendMapModel {
    struct Node: Decodable, Sendable {
        let key: String
        let userId: Int64?
        let kind: String
    }
    struct Graph: Decodable, Sendable {
        let nodes: [Node]
        let edges: [[String]]
    }

    private(set) var graph: Graph?
    /// Where each node sits, around (0, 0).
    private(set) var positions: [String: CGPoint] = [:]
    private let account: Account
    private let transport: any Transport

    init(account: Account, transport: any Transport = NetworkTransport()) {
        self.account = account
        self.transport = transport
    }

    func load() async throws {
        let graph = try Server.decoder.decode(Graph.self, from: await Server(account.server, transport: transport).send("graph", token: account.token))
        self.graph = graph
        positions = await Task.detached(priority: .userInitiated) { Self.layout(graph) }.value
    }

    /// A small force layout: linked people pull together, everyone pushes
    /// apart, you stay at the middle. The same graph always lands the same way
    /// (a fixed start and a fixed number of steps), so the picture doesn't jump.
    nonisolated static func layout(_ graph: Graph, steps: Int = 300) -> [String: CGPoint] {
        let keys = graph.nodes.map(\.key)
        let me = graph.nodes.first { $0.kind == "self" }?.key
        var p: [String: CGPoint] = [:]
        for (i, key) in keys.enumerated() {
            let angle = Double(i) * 2.399963  // the golden angle: an even spread to start from
            let r = 40 + 12 * Double(i).squareRoot() * 4
            p[key] = key == me ? .zero : CGPoint(x: cos(angle) * r, y: sin(angle) * r)
        }
        let links = graph.edges.filter { $0.count == 2 }.map { ($0[0], $0[1]) }
        for step in 0..<steps {
            var force = Dictionary(uniqueKeysWithValues: keys.map { ($0, CGPoint.zero) })
            for i in keys.indices {
                for j in keys.indices where j > i {
                    let a = keys[i], b = keys[j]
                    var dx = p[a]!.x - p[b]!.x, dy = p[a]!.y - p[b]!.y
                    if dx == 0 && dy == 0 { dx = 0.1; dy = 0.1 }
                    let d2 = max(dx * dx + dy * dy, 1)
                    let push = 4000 / d2
                    let d = d2.squareRoot()
                    force[a]!.x += dx / d * push; force[a]!.y += dy / d * push
                    force[b]!.x -= dx / d * push; force[b]!.y -= dy / d * push
                }
            }
            for (a, b) in links {
                guard let pa = p[a], let pb = p[b] else { continue }
                let dx = pb.x - pa.x, dy = pb.y - pa.y
                let d = max((dx * dx + dy * dy).squareRoot(), 0.01)
                let pull = (d - 70) * 0.05
                force[a]!.x += dx / d * pull; force[a]!.y += dy / d * pull
                force[b]!.x -= dx / d * pull; force[b]!.y -= dy / d * pull
            }
            let cool = 1 - Double(step) / Double(steps)
            for key in keys where key != me {
                let f = force[key]!
                let move = min((f.x * f.x + f.y * f.y).squareRoot(), 10 * cool + 0.5)
                let len = max((f.x * f.x + f.y * f.y).squareRoot(), 0.0001)
                p[key]!.x += f.x / len * move
                p[key]!.y += f.y / len * move
            }
        }
        return p
    }
}

struct FriendMapScreen: View {
    @Environment(Session.self) private var session
    @State var model: FriendMapModel
    /// Names for your friends, as you call them.
    let names: [Int64: String]
    let me: String
    @State private var scale: CGFloat = 1
    @State private var scaleFrom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetFrom: CGSize = .zero
    @State private var problem: String?

    var body: some View {
        // (Plain copies: the canvas draws off the main actor.)
        let graph = model.graph, positions = model.positions, zoom = scale, shift = offset, names = names, me = me
        return Canvas { context, size in
            guard let graph else { return }
            let center = CGPoint(x: size.width / 2 + shift.width, y: size.height / 2 + shift.height)
            func at(_ key: String) -> CGPoint? {
                positions[key].map { CGPoint(x: center.x + $0.x * zoom, y: center.y + $0.y * zoom) }
            }
            for edge in graph.edges where edge.count == 2 {
                guard let a = at(edge[0]), let b = at(edge[1]) else { continue }
                var line = Path()
                line.move(to: a)
                line.addLine(to: b)
                context.stroke(line, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
            }
            for node in graph.nodes {
                guard let p = at(node.key) else { continue }
                let r: CGFloat = node.kind == "self" ? 14 : node.kind == "friend" ? 10 : 6
                let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                context.fill(dot, with: .color(node.kind == "unknown" ? .secondary.opacity(0.5) : .accentColor))
                let label = node.kind == "self" ? me : node.kind == "friend" ? node.userId.flatMap { names[$0] } ?? "" : "?"
                context.draw(Text(label).font(node.kind == "unknown" ? .caption2 : .caption).foregroundStyle(.primary),
                             at: CGPoint(x: p.x, y: p.y + r + 9))
            }
        }
        .gesture(SimultaneousGesture(
            MagnifyGesture().onChanged { scale = min(max(0.3, scaleFrom * $0.magnification), 4) }.onEnded { _ in scaleFrom = scale },
            DragGesture().onChanged { offset = CGSize(width: offsetFrom.width + $0.translation.width, height: offsetFrom.height + $0.translation.height) }
                .onEnded { _ in offsetFrom = offset }))
        .overlay(alignment: .bottom) {
            Text(problem ?? caption).font(.footnote).foregroundStyle(problem == nil ? Color.secondary : .red)
                .multilineTextAlignment(.center).padding()
        }
        .overlay { if model.graph == nil && problem == nil { ProgressView() } }
        .accessibilityElement()
        .accessibilityLabel(caption)
        .navigationTitle("Friend map")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { try await model.load() } catch {
                problem = error.localizedDescription
                session.noticed(error)
            }
        }
    }

    /// What it shows, in words (and for VoiceOver).
    private var caption: String {
        guard let graph = model.graph else { return "" }
        let friends = graph.nodes.filter { $0.kind == "friend" }.count, unknown = graph.nodes.filter { $0.kind == "unknown" }.count
        return "You and \(friends) \(friends == 1 ? "friend" : "friends")" + (unknown > 0 ? ", and \(unknown) \(unknown == 1 ? "person" : "people") they know that you don't (shown as ?)." : ".")
    }
}
