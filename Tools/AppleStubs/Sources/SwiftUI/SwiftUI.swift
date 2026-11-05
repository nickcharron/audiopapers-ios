import Foundation
@_exported import UIKit
@_exported import Observation

// MARK: - Views

@MainActor public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor var body: Body { get }
}

extension Never: View {
    public var body: Never { fatalError() }
}

public protocol PrimitiveView: View where Body == Never {}
public extension PrimitiveView {
    var body: Never { fatalError() }
}

public struct AnyViewStub: PrimitiveView { public init() {} }
public struct EmptyView: PrimitiveView { public init() {} }
public struct TupleView<T>: PrimitiveView { public init(_ value: T) {} }
public struct ConditionalView<A: View, B: View>: PrimitiveView { public init() {} }
extension Optional: View where Wrapped: View {
    public var body: Never { fatalError() }
}

@MainActor @resultBuilder public struct ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<V: View>(_ view: V) -> V { view }
    public static func buildBlock<each V: View>(_ views: repeat each V) -> TupleView<(repeat each V)> { TupleView((repeat each views)) }
    public static func buildEither<A: View, B: View>(first: A) -> ConditionalView<A, B> { ConditionalView() }
    public static func buildEither<A: View, B: View>(second: B) -> ConditionalView<A, B> { ConditionalView() }
    public static func buildIf<V: View>(_ view: V?) -> V? { view }
    public static func buildLimitedAvailability<V: View>(_ view: V) -> V { view }
}

@resultBuilder public struct SceneBuilder {
    public static func buildBlock<S: Scene>(_ scene: S) -> S { scene }
}

@MainActor public protocol Scene {}
public struct WindowGroup<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
}

@MainActor public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
    init()
}
public extension App {
    static func main() {}
}

@propertyWrapper public struct UIApplicationDelegateAdaptor<Delegate: UIApplicationDelegate> {
    public init(_ type: Delegate.Type) {}
    public var wrappedValue: Delegate { fatalError() }
}

@propertyWrapper public struct State<Value> {
    public init(wrappedValue: Value) { box = Box(wrappedValue) }
    public init(initialValue: Value) { box = Box(initialValue) }
    private final class Box { var value: Value; init(_ value: Value) { self.value = value } }
    private let box: Box
    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    public var projectedValue: Binding<Value> { Binding(get: { box.value }, set: { box.value = $0 }) }
}
public extension State where Value: ExpressibleByNilLiteral {
    init() { self.init(wrappedValue: nil) }
}

@propertyWrapper @dynamicMemberLookup public struct Binding<Value> {
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) { self.get = get; self.set = set }
    private let get: () -> Value
    private let set: (Value) -> Void
    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }
    public var projectedValue: Binding<Value> { self }
    public subscript<T>(dynamicMember path: WritableKeyPath<Value, T>) -> Binding<T> { fatalError() }
}

@propertyWrapper @dynamicMemberLookup public struct Bindable<Value: AnyObject> {
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public var wrappedValue: Value
    public var projectedValue: Bindable<Value> { self }
    public subscript<T>(dynamicMember path: ReferenceWritableKeyPath<Value, T>) -> Binding<T> { fatalError() }
}

public enum ScenePhase: Equatable, Sendable { case background, inactive, active }
public struct EnvironmentValues { public var scenePhase = ScenePhase.active }
@propertyWrapper public struct Environment<Value> {
    public init(_ path: KeyPath<EnvironmentValues, Value>) {}
    public var wrappedValue: Value { fatalError() }
}

// MARK: - Styles and fonts

public protocol ShapeStyle: Sendable {}
public struct Color: ShapeStyle, View, Hashable, Sendable {
    public var body: Never { fatalError() }
    public init(_ name: String) {}
    public init(red: Double, green: Double, blue: Double) {}
    public func opacity(_ value: Double) -> Color { self }
    public static let accentColor = Color("")
    public static let secondary = Color("")
    public static let primary = Color("")
    public static let red = Color("")
}
public extension ShapeStyle where Self == Color {
    static var red: Color { Color.red }
    static var secondary: Color { Color.secondary }
    static var primary: Color { Color.primary }
}

public struct Font: Hashable, Sendable {
    public enum Weight: Sendable { case semibold, bold }
    public static let title2 = Font(), title3 = Font(), headline = Font(), subheadline = Font(), body = Font(), caption = Font(), footnote = Font()
    public func bold() -> Font { self }
    public func italic() -> Font { self }
    public func monospaced() -> Font { self }
}

public struct Text: PrimitiveView {
    public enum LineStyle: Hashable, Sendable { case single }
    public init(_ key: LocalizedStringKey) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ text: S) {}
    @_disfavoredOverload public init(_ text: AttributedString) {}
}

public struct LocalizedStringKey: ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
    public struct StringInterpolation: StringInterpolationProtocol {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation<T>(_ value: T) {}
        public mutating func appendInterpolation(_ value: Float, specifier: String) {}
    }
}

extension AttributeScopes {
    public struct SwiftUIAttributes: AttributeScope {
        public let backgroundColor: BackgroundColorKey
        public let font: FontKey
        public let underlineStyle: UnderlineKey
    }
    public var swiftUI: SwiftUIAttributes.Type { SwiftUIAttributes.self }
}
public enum BackgroundColorKey: AttributedStringKey {
    public typealias Value = Color
    public static let name = "backgroundColor"
}
public enum FontKey: AttributedStringKey {
    public typealias Value = Font
    public static let name = "font"
}
public enum UnderlineKey: AttributedStringKey {
    public typealias Value = Text.LineStyle
    public static let name = "underline"
}
extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember path: KeyPath<AttributeScopes.SwiftUIAttributes, T>) -> T { self[T.self] }
}

// MARK: - Containers

public enum HorizontalAlignment { case leading, center, trailing }
public enum VerticalAlignment { case top, center, firstTextBaseline }
public struct Alignment: Sendable { public static let leading = Alignment(), center = Alignment() }
public enum TextAlignment { case leading, center }
public struct Edge { public static let top = Edge() }
public struct EdgeSet: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let top = EdgeSet(rawValue: 1), bottom = EdgeSet(rawValue: 2), leading = EdgeSet(rawValue: 4), horizontal = EdgeSet(rawValue: 8), vertical = EdgeSet(rawValue: 16)
}
public struct EdgeInsets { public init() {} }

public struct VStack<Content: View>: PrimitiveView {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}
public struct HStack<Content: View>: PrimitiveView {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}
public struct ZStack<Content: View>: PrimitiveView {
    public init(@ViewBuilder content: () -> Content) {}
}
public struct Group<Content: View>: PrimitiveView {
    public init(@ViewBuilder content: () -> Content) {}
}
public struct ScrollView<Content: View>: PrimitiveView {
    public init(@ViewBuilder content: () -> Content) {}
}
public struct Spacer: PrimitiveView {
    public init(minLength: CGFloat? = nil) {}
}
public struct Divider: PrimitiveView { public init() {} }
public struct List<Content: View>: PrimitiveView {
    public init<Data: RandomAccessCollection, Row: View>(_ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> Row) where Data.Element: Identifiable, Content == Row {}
}
public struct ForEach<Content: View>: PrimitiveView {
    public init<Data: RandomAccessCollection, Row: View>(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Row) where Data.Element: Identifiable, Content == Row {}
    public init<Data: RandomAccessCollection, ID: Hashable, Row: View>(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Row) where Content == Row {}
}
public struct NavigationStack<Root: View>: PrimitiveView {
    public init<Data>(path: Binding<Data>, @ViewBuilder root: () -> Root) {}
}

// MARK: - Controls

public struct ButtonRole { public static let destructive = ButtonRole(), cancel = ButtonRole() }
public struct Button<Label: View>: PrimitiveView {
    public init(role: ButtonRole? = nil, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {}
}
public extension Button where Label == Text {
    init(_ title: String, role: ButtonRole? = nil, action: @escaping @MainActor () -> Void) {}
}
public struct Label<Title: View, Icon: View>: PrimitiveView {}
public extension Label where Title == Text, Icon == Image {
    init(_ title: String, systemImage: String) {}
}
public struct Image: PrimitiveView {
    public init(_ name: String) {}
    public init(systemName: String) {}
    public init(uiImage: UIImage) {}
    public func resizable() -> Image { self }
    public func scaledToFit() -> Image { self }
}
public struct ProgressView: PrimitiveView {
    public init() {}
    public init(value: Double, total: Double = 1) {}
}
public enum ControlSize { case small }
public struct Menu<Label: View, Content: View>: PrimitiveView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
}
public extension Menu where Label == Text {
    init(_ title: String, @ViewBuilder content: () -> Content) {}
}
public struct Toggle<Label: View>: PrimitiveView {
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {}
}
public enum Axis { case vertical }
public struct TextField: PrimitiveView {
    public init(_ title: String, text: Binding<String>, axis: Axis? = nil) {}
}
public struct SecureField: PrimitiveView {
    public init(_ title: String, text: Binding<String>) {}
}
public struct Link: PrimitiveView {
    public init(_ title: String, destination: URL) {}
}
public struct ShareLink: PrimitiveView {
    public init(_ title: String, item: URL) {}
}

// MARK: - Shapes

public struct StrokeStyle { public init(lineWidth: CGFloat, lineCap: LineCap = .butt) {} }
public enum LineCap { case butt, round }
public struct Angle { public static func degrees(_ value: Double) -> Angle { Angle() } }
@MainActor public protocol Shape: View {}
public struct AnyShapeView: PrimitiveView {}
@MainActor public extension Shape {
    func fill(_ color: Color) -> AnyShapeView { AnyShapeView() }
    func stroke(_ color: Color, lineWidth: CGFloat) -> AnyShapeView { AnyShapeView() }
    func stroke(_ color: Color, style: StrokeStyle) -> AnyShapeView { AnyShapeView() }
    func trim(from: Double, to: Double) -> Circle { Circle() }
}
public struct Circle: Shape, PrimitiveView { public init() {} }
public struct RoundedRectangle: Shape, PrimitiveView { public init(cornerRadius: CGFloat) {} }
public struct Rectangle: Shape, PrimitiveView { public init() {} }

// MARK: - Styles for controls

public protocol ButtonStyleStub {}
public struct BorderedStyle: ButtonStyleStub {}
public struct BorderedProminentStyle: ButtonStyleStub {}
public extension ButtonStyleStub where Self == BorderedStyle { static var bordered: BorderedStyle { BorderedStyle() } }
public extension ButtonStyleStub where Self == BorderedProminentStyle { static var borderedProminent: BorderedProminentStyle { BorderedProminentStyle() } }
public enum TextFieldStyleStub { case roundedBorder }
public enum ListStyleStub { case plain }
public enum TextInputAutocapitalization { case never }
public struct TextSelectability { public static let enabled = TextSelectability() }
public enum NavigationBarItemTitleDisplayMode { case inline }
public enum Visibility { case hidden }
public enum ToolbarPlacement { case navigationBar }
public struct PresentationDetent: Hashable { public static let medium = PresentationDetent(), large = PresentationDetent() }
public enum ScrollPhase: Sendable { case idle, tracking, interacting, decelerating, animating }
public struct ScrollGeometry { public var contentOffset: CGPoint = .zero; public var contentSize: CGSize = .zero; public var containerSize: CGSize = .zero }
public struct ScrollPosition {
    public init(edge: Edge? = nil) {}
    public mutating func scrollTo(y: CGFloat) {}
}
public enum CoordinateSpaceStub { case named(String) }
public struct GeometryProxy { public func frame(in space: CoordinateSpaceStub) -> CGRect { .zero } }
public struct ContentShapeStub {}

@MainActor public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = AnyViewStub
    @ViewBuilder func body(content: Content) -> Body
}

public struct ModifiedView: PrimitiveView {}

public func withAnimation<T>(_ body: () -> T) -> T { body() }

public extension View {
    func font(_ font: Font) -> some View { ModifiedView() }
    func fontWeight(_ weight: Font.Weight) -> some View { ModifiedView() }
    func bold() -> some View { ModifiedView() }
    func foregroundStyle<S: ShapeStyle>(_ style: S) -> some View { ModifiedView() }
    func padding(_ edges: EdgeSet, _ length: CGFloat? = nil) -> some View { ModifiedView() }
    func padding(_ length: CGFloat) -> some View { ModifiedView() }
    func frame(width: CGFloat? = nil, height: CGFloat? = nil) -> some View { ModifiedView() }
    func frame(maxWidth: CGFloat? = nil, maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> some View { ModifiedView() }
    func multilineTextAlignment(_ alignment: TextAlignment) -> some View { ModifiedView() }
    func lineLimit(_ count: Int?) -> some View { ModifiedView() }
    func minimumScaleFactor(_ factor: CGFloat) -> some View { ModifiedView() }
    func background<S: ShapeStyle, T: Shape>(_ style: S, in shape: T) -> some View { ModifiedView() }
    func clipShape<T: Shape>(_ shape: T) -> some View { ModifiedView() }
    func accessibilityLabel(_ label: String) -> some View { ModifiedView() }
    func task<T: Equatable>(id: T, @_inheritActorContext _ action: @escaping @Sendable () async -> Void) -> some View { ModifiedView() }
    func onAppear(perform action: (() -> Void)? = nil) -> some View { ModifiedView() }
    func onDisappear(perform action: (() -> Void)? = nil) -> some View { ModifiedView() }
    func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View { ModifiedView() }
    func sheet<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View { ModifiedView() }
    func alert<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View { ModifiedView() }
    func alert<A: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A) -> some View { ModifiedView() }
    func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTTypeStub], onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View { ModifiedView() }
    func toolbar(_ visibility: Visibility, for placement: ToolbarPlacement) -> some View { ModifiedView() }
    func tint(_ color: Color) -> some View { ModifiedView() }
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItemTitleDisplayMode) -> some View { ModifiedView() }
    func navigationDestination<D: Hashable, C: View>(for type: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View { ModifiedView() }
    func buttonStyle<S: ButtonStyleStub>(_ style: S) -> some View { ModifiedView() }
    func disabled(_ disabled: Bool) -> some View { ModifiedView() }
    func listStyle(_ style: ListStyleStub) -> some View { ModifiedView() }
    func listRowInsets(_ insets: EdgeInsets?) -> some View { ModifiedView() }
    func contentShape<T: Shape>(_ shape: T) -> some View { ModifiedView() }
    func onTapGesture(perform action: @escaping () -> Void) -> some View { ModifiedView() }
    func textFieldStyle(_ style: TextFieldStyleStub) -> some View { ModifiedView() }
    func textInputAutocapitalization(_ value: TextInputAutocapitalization?) -> some View { ModifiedView() }
    func autocorrectionDisabled(_ disabled: Bool = true) -> some View { ModifiedView() }
    func textSelection(_ value: TextSelectability) -> some View { ModifiedView() }
    func presentationDetents(_ detents: Set<PresentationDetent>) -> some View { ModifiedView() }
    func interactiveDismissDisabled(_ disabled: Bool = true) -> some View { ModifiedView() }
    func scrollPosition(_ position: Binding<ScrollPosition>) -> some View { ModifiedView() }
    func onScrollPhaseChange(_ action: @escaping (ScrollPhase, ScrollPhase) -> Void) -> some View { ModifiedView() }
    func onScrollGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (ScrollGeometry) -> T, action: @escaping (T, T) -> Void) -> some View { ModifiedView() }
    func onGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T, action: @escaping (T) -> Void) -> some View { ModifiedView() }
    func coordinateSpace(name: String) -> some View { ModifiedView() }
    func modifier<M: ViewModifier>(_ modifier: M) -> some View { ModifiedView() }
    func rotationEffect(_ angle: Angle) -> some View { ModifiedView() }
    func controlSize(_ size: ControlSize) -> some View { ModifiedView() }
}

public typealias UTTypeStub = UniformTypeIdentifiersType
public struct UniformTypeIdentifiersType { public static let pdf = UniformTypeIdentifiersType() }

// MARK: - UIKit in SwiftUI

public struct UIViewRepresentableContext<R: UIViewRepresentable> {
    public var coordinator: R.Coordinator { fatalError() }
}

@MainActor public protocol UIViewRepresentable: View where Body == Never {
    associatedtype UIViewType: UIView
    associatedtype Coordinator = Void
    typealias Context = UIViewRepresentableContext<Self>
    func makeUIView(context: Context) -> UIViewType
    func updateUIView(_ view: UIViewType, context: Context)
    func makeCoordinator() -> Coordinator
    static func dismantleUIView(_ view: UIViewType, coordinator: Coordinator)
}
public extension UIViewRepresentable {
    var body: Never { fatalError() }
    static func dismantleUIView(_ view: UIViewType, coordinator: Coordinator) {}
}
public extension UIViewRepresentable where Coordinator == Void {
    func makeCoordinator() -> Void {}
}
