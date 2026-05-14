import Foundation
let query = "limit=10&limit=20"
let pairs = query.split(separator: "&").compactMap { pair -> (String, String)? in
    let parts = pair.split(separator: "=", maxSplits: 1)
    guard let name = parts.first else { return nil }
    let value = parts.count == 2 ? String(parts[1]) : ""
    return (String(name), value.removingPercentEncoding ?? value)
}
let dict = Dictionary(uniqueKeysWithValues: pairs)
print(dict)
