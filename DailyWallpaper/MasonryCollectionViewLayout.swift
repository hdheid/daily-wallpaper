import AppKit

@MainActor
final class MasonryCollectionViewLayout: NSCollectionViewLayout {
    var aspectRatioProvider: ((IndexPath) -> CGFloat)?

    private let horizontalInset: CGFloat = 16
    private let verticalInset: CGFloat = 16
    private let spacing: CGFloat = 12
    // 适当减少列数，让用户无需打开原图也能看清壁纸主体和介绍文字。
    private let preferredItemWidth: CGFloat = 320
    private let minimumItemWidth: CGFloat = 280
    private let maximumItemWidth: CGFloat = 400

    private var cachedAttributes: [NSCollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var preparedWidth: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        guard width > 0 else { return }

        let itemCount = collectionView.numberOfItems(inSection: 0)
        cachedAttributes.removeAll(keepingCapacity: true)
        preparedWidth = width
        guard itemCount > 0 else {
            contentHeight = 0
            return
        }

        let availableWidth = max(1, width - horizontalInset * 2)
        var columnCount = max(1, Int((availableWidth + spacing) / (preferredItemWidth + spacing)))
        var itemWidth = (availableWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
        while itemWidth > maximumItemWidth {
            columnCount += 1
            itemWidth = (availableWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
        }
        while columnCount > 1, itemWidth < minimumItemWidth {
            columnCount -= 1
            itemWidth = (availableWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
        }

        var columnHeights = Array(repeating: verticalInset, count: columnCount)
        for itemIndex in 0 ..< itemCount {
            let indexPath = IndexPath(item: itemIndex, section: 0)
            let shortestColumn = columnHeights.indices.min(by: { columnHeights[$0] < columnHeights[$1] }) ?? 0
            let rawRatio = aspectRatioProvider?(indexPath) ?? 1
            // 使用原图宽高比决定卡片高度；只有索引尺寸无效时才退回正方形。
            let displayRatio = rawRatio.isFinite && rawRatio > 0 ? rawRatio : 1
            let imageHeight = itemWidth / displayRatio
            let x = horizontalInset + CGFloat(shortestColumn) * (itemWidth + spacing)
            let y = columnHeights[shortestColumn]

            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = NSRect(x: x, y: y, width: itemWidth, height: imageHeight)
            cachedAttributes.append(attributes)
            columnHeights[shortestColumn] = y + imageHeight + spacing
        }
        contentHeight = (columnHeights.max() ?? 0) + verticalInset - spacing
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: preparedWidth, height: max(contentHeight, collectionView?.bounds.height ?? 0))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        cachedAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < cachedAttributes.count else { return nil }
        return cachedAttributes[indexPath.item]
    }

    /// 分页插入的新卡片从透明渐显入场。
    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let attributes = layoutAttributesForItem(at: itemIndexPath)?.copy() as? NSCollectionViewLayoutAttributes else {
            return nil
        }
        attributes.alpha = 0
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }
}
