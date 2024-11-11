//
//  ReverseList.swift
//  SimpleX (iOS)
//
//  Created by Levitating Pineapple on 11/06/2024.
//  Copyright © 2024 SimpleX Chat. All rights reserved.
//

import SwiftUI
import Combine
import SimpleXChat

/// A List, which displays it's items in reverse order - from bottom to top
struct ReverseList<Content: View>: UIViewControllerRepresentable {
    let groups: SectionGroups

    @Binding var scrollState: ReverseListScrollModel.State
    @Binding var initialChatItem: ChatItem?

    /// Closure, that returns user interface for a given item
    let content: (ListItem) -> Content

    let loadPage: (_ pagination: ChatPagination) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(representer: self)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.representer = self
        if case let .scrollingTo(destination) = scrollState, !groups.sections.isEmpty {
            controller.view.layer.removeAllAnimations()
            switch destination {
            case .nextPage:
                controller.scrollToNextPage()
            case let .item(id):
                controller.scroll(to: getIndexInParentItems(sections: groups.sections, itemId: id), position: .bottom)
            case .bottom:
                controller.scroll(to: 0, position: .top)
            }
        } else {
            controller.update(groups: groups)
        }
    }

    /// Controller, which hosts SwiftUI cells
    class Controller: UITableViewController {
        private enum Section { case main }
        var representer: ReverseList
        private var dataSource: UITableViewDiffableDataSource<Section, ListItem>!
        private var itemCount: Int = 0
        private let updateFloatingButtons = PassthroughSubject<Void, Never>()
        private var bag = Set<AnyCancellable>()
        private var revealedItems: Array<ListItem> = []

        init(representer: ReverseList) {
            self.representer = representer
            super.init(style: .plain)

            // 1. Style
            tableView = InvertedTableView()
            tableView.separatorStyle = .none
            tableView.transform = .verticalFlip
            tableView.backgroundColor = .clear

            // 2. Register cells
            if #available(iOS 16.0, *) {
                tableView.register(
                    UITableViewCell.self,
                    forCellReuseIdentifier: cellReuseId
                )
            } else {
                tableView.register(
                    HostingCell<Content>.self,
                    forCellReuseIdentifier: cellReuseId
                )
            }

            // 3. Configure data source
            self.dataSource = UITableViewDiffableDataSource<Section, ListItem>(
                tableView: tableView
            ) { (tableView, indexPath, item) -> UITableViewCell? in
                if self.representer.scrollState == .atDestination, self.representer.initialChatItem == nil {
                    if indexPath.item > self.itemCount - preloadItem,
                       let item = getNewestItemAtParentIndexOrNull(sections: self.representer.groups.sections, parentIndex: self.itemCount - 1) {
                        self.representer.loadPage(.before(chatItemId: item.id, count: loadItemsPerPage))
                    } else if let item = self.getFirstItemAfterPlacholder(indexPath) {
                        self.representer.loadPage(.after(chatItemId: item.id, count: loadItemsPerPage))
                    }
                }
                let cell = tableView.dequeueReusableCell(withIdentifier: cellReuseId, for: indexPath)
                if #available(iOS 16.0, *) {
                    cell.contentConfiguration = UIHostingConfiguration { self.representer.content(item) }
                        .margins(.all, 0)
                        .minSize(height: 1) // Passing zero will result in system default of 44 points being used
                } else {
                    if let cell = cell as? HostingCell<Content> {
                        cell.set(content: self.representer.content(item), parent: self)
                    } else {
                        fatalError("Unexpected Cell Type for: \(item)")
                    }
                }
                cell.transform = .verticalFlip
                cell.selectionStyle = .none
                cell.backgroundColor = .clear
                return cell
            }

            // 4. External state changes will require manual layout updates
            NotificationCenter.default
                .addObserver(
                    self,
                    selector: #selector(updateLayout),
                    name: notificationName,
                    object: nil
                )

            updateFloatingButtons
                .throttle(for: 0.2, scheduler: DispatchQueue.global(qos: .background), latest: true)
                .sink {
                    if let listState = DispatchQueue.main.sync(execute: { [weak self] in self?.getListState() }) {
                        ChatView.FloatingButtonModel.shared.updateOnListChange(listState)
                    }
                }
                .store(in: &bag)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func updateLayout() {
            if #available(iOS 16.0, *) {
                tableView.setNeedsLayout()
                tableView.layoutIfNeeded()
            } else {
                tableView.reloadData()
            }
        }

        /// Hides keyboard, when user begins to scroll.
        /// Equivalent to `.scrollDismissesKeyboard(.immediately)`
        override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            UIApplication.shared
                .sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
            NotificationCenter.default.post(name: .chatViewWillBeginScrolling, object: nil)
        }

        override func viewDidAppear(_ animated: Bool) {
            tableView.clipsToBounds = false
            parent?.viewIfLoaded?.clipsToBounds = false
        }
        
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if let cItem = self.representer.initialChatItem {
                let index = getIndexInParentItems(sections: self.representer.groups.sections, itemId: cItem.id)
                
                if index == -1 {
                    return
                }
                let indexPath = IndexPath(row: index, section: 0)
                if !isVisible(indexPath: indexPath) {
                    if tableView.numberOfRows(inSection: indexPath.section) > indexPath.row {
                        let cellRect = tableView.rectForRow(at: indexPath)
                        tableView.setContentOffset(CGPoint(x: 0, y: cellRect.maxY - tableView.bounds.height), animated: false)
                    }
                }
                Task {
                    DispatchQueue.main.async {
                        self.representer.initialChatItem = nil
                    }
                }
            }
        }

        /// Scrolls up
        func scrollToNextPage() {
            tableView.setContentOffset(
                CGPoint(
                    x: tableView.contentOffset.x,
                    y: tableView.contentOffset.y + tableView.bounds.height
                ),
                animated: true
            )
            Task { representer.scrollState = .atDestination }
        }

        /// Scrolls to Item at index path
        /// - Parameter indexPath: Item to scroll to - will scroll to beginning of the list, if `nil`
        func scroll(to index: Int?, position: UITableView.ScrollPosition) {
            var animated = false
            if #available(iOS 16.0, *) {
                animated = true
            }

            if let index, tableView.numberOfRows(inSection: 0) != 0 {
                tableView.scrollToRow(
                    at: IndexPath(row: index, section: 0),
                    at: position,
                    animated: animated
                )
            } else {
                tableView.setContentOffset(
                    CGPoint(x: .zero, y: -InvertedTableView.inset),
                    animated: animated
                )
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task {
                    self.representer.scrollState = .atDestination
                }
            }
        }

        func update(groups: SectionGroups) {
            var snapshot = NSDiffableDataSourceSnapshot<Section, ListItem>()
            revealedItems.removeAll()
            groups.sections.forEach { sc in
                if sc.revealed {
                    revealedItems.append(contentsOf: sc.items)
                } else if let item = sc.items.first {
                    revealedItems.append(item)
                }
            }
            snapshot.appendSections([.main])
            snapshot.appendItems(revealedItems, toSection: .main)
            dataSource.defaultRowAnimation = .none
            
            let countDiff = max(0, revealedItems.count - itemCount)
            if tableView.contentOffset.y == 100, itemCount < revealedItems.count, itemCount > 0 {
                dataSource.apply(
                    snapshot,
                    animatingDifferences: false
                )
                
                tableView.scrollToRow(
                    at: IndexPath(row: countDiff, section: 0),
                    at: .top,
                    animated: false
                )
            } else {
                tableView.beginUpdates()
                dataSource.apply(
                    snapshot,
                    animatingDifferences: false
                )
                tableView.endUpdates()
            }

            // Sets content offset on initial load
            if itemCount == 0 {
                tableView.setContentOffset(
                    CGPoint(x: 0, y: -InvertedTableView.inset),
                    animated: false
                )
            }
            itemCount = revealedItems.count
            updateFloatingButtons.send()
        }

        override func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateFloatingButtons.send()
        }

        func getListState() -> ListState? {
            if let visibleRows = tableView.indexPathsForVisibleRows,
               visibleRows.last?.item ?? 0 < revealedItems.count {
                let scrollOffset: Double = tableView.contentOffset.y + InvertedTableView.inset
                
                let topItemDate: Date? =
                    if let lastVisible = visibleRows.last(where: { isVisible(indexPath: $0) }) {
                        revealedItems[lastVisible.item].item.meta.itemTs
                    } else {
                        nil
                    }
                let bottomItemId: ChatItem.ID? =
                    if let firstVisible = visibleRows.first(where: { isVisible(indexPath: $0) }) {
                        revealedItems[firstVisible.item].item.id
                    } else {
                        nil
                    }
                return (scrollOffset: scrollOffset, topItemDate: topItemDate, bottomItemId: bottomItemId)
            }
            return nil
        }
        
        private func isVisible(indexPath: IndexPath) -> Bool {
            if let relativeFrame = tableView.superview?.convert(
                tableView.rectForRow(at: indexPath),
                from: tableView
            ) {
                relativeFrame.maxY > InvertedTableView.inset &&
                relativeFrame.minY < tableView.frame.height - InvertedTableView.inset
            } else { false }
        }
        
        private func getFirstItemAfterPlacholder(_ indexPath: IndexPath) -> ChatItem? {
            return nil
        }
    }

    /// `UIHostingConfiguration` back-port for iOS14 and iOS15
    /// Implemented as a `UITableViewCell` that wraps and manages a generic `UIHostingController`
    private final class HostingCell<Hosted: View>: UITableViewCell {
        private let hostingController = UIHostingController<Hosted?>(rootView: nil)

        /// Updates content of the cell
        /// For reference: https://noahgilmore.com/blog/swiftui-self-sizing-cells/
        func set(content: Hosted, parent: UIViewController) {
            hostingController.view.backgroundColor = .clear
            hostingController.rootView = content
            if let hostingView = hostingController.view {
                hostingView.invalidateIntrinsicContentSize()
                if hostingController.parent != parent { parent.addChild(hostingController) }
                if !contentView.subviews.contains(hostingController.view) {
                    contentView.addSubview(hostingController.view)
                    hostingView.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        hostingView.leadingAnchor
                            .constraint(equalTo: contentView.leadingAnchor),
                        hostingView.trailingAnchor
                            .constraint(equalTo: contentView.trailingAnchor),
                        hostingView.topAnchor
                            .constraint(equalTo: contentView.topAnchor),
                        hostingView.bottomAnchor
                            .constraint(equalTo: contentView.bottomAnchor)
                    ])
                }
                if hostingController.parent != parent { hostingController.didMove(toParent: parent) }
            } else {
                fatalError("Hosting View not loaded \(hostingController)")
            }
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            hostingController.rootView = nil
        }
    }
}

typealias ListState = (
    scrollOffset: Double,
    topItemDate: Date?,
    bottomItemId: ChatItem.ID?
)

/// Manages ``ReverseList`` scrolling
class ReverseListScrollModel: ObservableObject {
    /// Represents Scroll State of ``ReverseList``
    enum State: Equatable {
        enum Destination: Equatable {
            case nextPage
            case item(ChatItem.ID)
            case bottom
        }

        case scrollingTo(Destination)
        case atDestination
    }

    @Published var state: State = .atDestination

    func scrollToNextPage() {
        state = .scrollingTo(.nextPage)
    }

    func scrollToBottom() {
        state = .scrollingTo(.bottom)
    }

    func scrollToItem(id: ChatItem.ID) {
        state = .scrollingTo(.item(id))
    }
}

fileprivate let cellReuseId = "hostingCell"

fileprivate let notificationName = NSNotification.Name(rawValue: "reverseListNeedsLayout")

fileprivate extension CGAffineTransform {
    /// Transform that vertically flips the view, preserving it's location
    static let verticalFlip = CGAffineTransform(scaleX: 1, y: -1)
}

extension NotificationCenter {
    static func postReverseListNeedsLayout() {
        NotificationCenter.default.post(
            name: notificationName,
            object: nil
        )
    }
}

/// Disable animation on iOS 15
func withConditionalAnimation<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
) rethrows -> Result {
    if #available(iOS 16.0, *) {
        try withAnimation(animation, body)
    } else {
        try body()
    }
}

class InvertedTableView: UITableView {
    static let inset = CGFloat(100)

    static let insets = UIEdgeInsets(
        top: inset,
        left: .zero,
        bottom: inset,
        right: .zero
    )

    override var contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior {
        get { .never }
        set { }
    }

    override var contentInset: UIEdgeInsets {
        get { Self.insets }
        set { }
    }

    override var adjustedContentInset: UIEdgeInsets {
        Self.insets
    }
}
