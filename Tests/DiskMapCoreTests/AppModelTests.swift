import Testing
import Foundation
@testable import DiskMapCore

@Suite struct MapNavigationTests {
    /// "/" → Users → ana → Proyectos, más un archivo suelto y un agregado "Otros".
    private func tree() -> (root: FileNode, users: FileNode, ana: FileNode, projects: FileNode,
                            file: FileNode, others: FileNode) {
        let projects = FileNode(name: "Proyectos", isDirectory: true, allocatedSize: 10)
        let ana = FileNode(name: "ana", isDirectory: true, allocatedSize: 10, children: [projects])
        let users = FileNode(name: "Users", isDirectory: true, allocatedSize: 10, children: [ana])
        let file = FileNode(name: "swapfile", isDirectory: false, allocatedSize: 5)
        let others = FileNode(name: "Otros", isDirectory: false, allocatedSize: 3, aggregatedCount: 12)
        let root = FileNode(name: "/", isDirectory: true, allocatedSize: 18, children: [users, file, others])
        return (root, users, ana, projects, file, others)
    }

    @Test func zoomPushesAndBreadcrumb() {
        let t = tree()
        var navigation = MapNavigation(root: t.root, rootTitle: "Macintosh HD")
        #expect(navigation.breadcrumb == ["Macintosh HD"])
        navigation.zoom(into: t.users)
        navigation.zoom(into: t.ana)
        #expect(navigation.breadcrumb == ["Macintosh HD", "Users", "ana"])
        #expect(navigation.current === t.ana)
        #expect(navigation.stack.count == 3)
    }

    @Test func zoomOutAtRootIsNoop() {
        let t = tree()
        var navigation = MapNavigation(root: t.root, rootTitle: "Macintosh HD")
        navigation.zoomOut()
        #expect(navigation.current === t.root)
        #expect(navigation.breadcrumb == ["Macintosh HD"])

        navigation.zoom(into: t.users)
        navigation.zoomOut()
        #expect(navigation.current === t.root)
        navigation.zoomOut()
        #expect(navigation.stack.count == 1)
    }

    @Test func jumpTruncatesStack() {
        let t = tree()
        var navigation = MapNavigation(root: t.root, rootTitle: "Macintosh HD")
        navigation.zoom(into: t.users)
        navigation.zoom(into: t.ana)
        navigation.zoom(into: t.projects)
        navigation.jump(to: 1)
        #expect(navigation.current === t.users)
        #expect(navigation.breadcrumb == ["Macintosh HD", "Users"])
        navigation.jump(to: 0)
        #expect(navigation.current === t.root)
        #expect(navigation.stack.count == 1)
    }

    @Test func jumpOutOfRangeIsNoop() {
        let t = tree()
        var navigation = MapNavigation(root: t.root, rootTitle: "Macintosh HD")
        navigation.zoom(into: t.users)
        navigation.jump(to: 5)
        navigation.jump(to: -1)
        #expect(navigation.current === t.users)
    }

    @Test func zoomIgnoresFilesAggregatesAndStrangers() {
        let t = tree()
        var navigation = MapNavigation(root: t.root, rootTitle: "Macintosh HD")
        navigation.zoom(into: t.file)
        navigation.zoom(into: t.others)
        navigation.zoom(into: FileNode(name: "ajeno", isDirectory: true))
        navigation.zoom(into: t.root)
        #expect(navigation.current === t.root)
        #expect(navigation.stack.count == 1)
    }

    @Test func zoomIntoDeepDescendantPushesIntermediateLevels() {
        let t = tree()
        var navigation = MapNavigation(root: t.root, rootTitle: "Macintosh HD")
        navigation.zoom(into: t.projects)
        #expect(navigation.breadcrumb == ["Macintosh HD", "Users", "ana", "Proyectos"])
        navigation.zoomOut()
        #expect(navigation.current === t.ana)
    }

    @Test func emptyNavigationHasNoCurrent() {
        var navigation = MapNavigation(rootTitle: "Macintosh HD")
        #expect(navigation.current == nil)
        #expect(navigation.breadcrumb == ["Macintosh HD"])
        navigation.zoomOut()
        navigation.jump(to: 0)
        #expect(navigation.stack.isEmpty)
    }
}
