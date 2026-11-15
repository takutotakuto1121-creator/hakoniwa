import Foundation
import HakoniwaCore

/// Starts the encyclopedia and pet stores, and handles their launch flags for automated screenshots:
/// `--encyclopedia`, `--species ID|auto`, `--ency-sort population|birth|diet`,
/// `--ency-filter all|alive|extinct`, `--pet-name NAME` (names the `--select-first` creature),
/// `--favorites` (opens the favourites panel), `--ency-scroll-bottom` (shows the lower part of a detail page).
enum EncyclopediaLaunch {
    struct Flags {
        var open = false
        var species: String?
        var sort: EncyclopediaSort?
        var filter: EncyclopediaFilter?
        var petName: String?
        var favorites = false
        var scrollToBottom = false
    }

    static let flags: Flags = {
        var f = Flags()
        let a = CommandLine.arguments
        var i = 1
        func next() -> String? { i += 1; return i < a.count ? a[i] : nil }
        while i < a.count {
            switch a[i] {
            case "--encyclopedia": f.open = true
            case "--species": f.species = next(); f.open = true
            case "--ency-sort": f.sort = next().flatMap { EncyclopediaSort(rawValue: $0) }
            case "--ency-filter": f.filter = next().flatMap { EncyclopediaFilter(rawValue: $0) }
            case "--pet-name": f.petName = next()
            case "--favorites": f.favorites = true
            case "--ency-scroll-bottom": f.scrollToBottom = true
            default: break
            }
            i += 1
        }
        return f
    }()

    static func apply(model: AppModel, renderer r: Renderer) {
        let store = EncyclopediaStore.shared
        store.start()
        PetStore.shared.start()
        let f = flags
        if let s = f.sort { store.sort = s }
        if let s = f.filter { store.filter = s }
        if f.favorites { PetStore.shared.showFavorites = true }
        if let name = f.petName {
            // Wait for `--select-first` to deliver the selection's details, then name it.
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
                guard let d = model.detail else { return }
                t.invalidate()
                PetStore.shared.setName(name, for: d)
            }
        }
        guard f.open else { return }
        if let s = f.species {
            if let id = Int32(s) {
                store.open(species: id)
            } else {
                // "auto": among thriving species, the one with the richest family (ancestors and descendants).
                model.controller.perform { w in
                    var living = w.species.filter { $0.established && $0.population >= 20 }
                    if living.isEmpty { living = w.species.filter { $0.established && $0.population > 0 } }
                    var kids: [Int32: Int] = [:]
                    for s in w.species where s.established && s.parentId >= 0 { kids[s.parentId, default: 0] += 1 }
                    func score(_ s: SpeciesRecord) -> Int { w.lineage(of: s.id).count + 2 * (kids[s.id] ?? 0) }
                    let pick = living.max { a, b in
                        score(a) != score(b) ? score(a) < score(b) : a.population < b.population
                    }
                    DispatchQueue.main.async { store.open(species: pick?.id) }
                }
            }
        } else {
            store.open()
        }
    }
}
