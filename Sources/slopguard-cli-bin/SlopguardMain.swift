import SlopguardCLI

@main
@available(macOS 10.15, *)
struct SlopguardMain {
    static func main() async {
        await Slopguard.main()
    }
}
