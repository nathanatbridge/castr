import Foundation

/// Ground truth for the fixtures: one rod, described once.
///
/// The CSV fixture's acceleration is derived from `armBody`, so that constant
/// is genuinely encoded in the data and `tools/verify-reconstruction.js` has to
/// recover it. The rod constants are different in kind — the tip path is a
/// projection applied *after* the fit, so `axisBody` and `tipFromSensorM` leave
/// no trace in the CSV at all. They are here so the two fixtures describe the
/// same rod, and so the verifier has something to check the projection against.
///
/// Change a value here and change it in `tools/verify-reconstruction.js` too.
enum FixtureRod {
    /// Pivot to sensor, in the sensor's frame. 29.0 cm.
    static let armBody = [0.08, -0.10, -0.26]

    /// Butt to tip, in the sensor's frame, unit length. Close to the arm's own
    /// direction — the blank does run roughly away from the wrist — but not
    /// collinear with it, because a real mount is not.
    static let axisBody: [Double] = {
        let v = [0.31, -0.36, -0.88]
        let n = (v[0]*v[0] + v[1]*v[1] + v[2]*v[2]).squareRoot()
        return v.map { $0 / n }
    }()

    /// Sensor to tip. A 9 ft rod with the housing 30 cm up the handle.
    static let tipFromSensorM = 2.44
}
