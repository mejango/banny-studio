public extension Settings {
    /// Frame (w, h) to adopt when a backdrop is added, or nil to leave the
    /// frame alone. Fires only for the project's first backdrop while the
    /// frame is still the untouched 16:9 default, so an explicit choice is
    /// never overridden. Returns the asset's reduced pixel ratio
    /// (1200×1200 → 1:1, which the frame picker shows as Square).
    func autoFrame(assetPixelW: Int, assetPixelH: Int,
                   hasBackgroundCues: Bool) -> (w: Double, h: Double)? {
        guard !hasBackgroundCues, frameW == 16, frameH == 9,
              assetPixelW > 0, assetPixelH > 0 else { return nil }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(assetPixelW, assetPixelH)
        return (Double(assetPixelW / g), Double(assetPixelH / g))
    }
}
