import Foundation

extension World {
    func sample() {
        var herb: Int32 = 0, omni: Int32 = 0, carn: Int32 = 0
        var sumSize: Double = 0, sumSpeed: Double = 0, sumView: Double = 0, sumConn: Double = 0, sumGen: Double = 0
        var creatureEnergy: Double = 0
        var alive = 0
        // Per-species trait accumulation.
        var acc: [Int32: (n: Int, diet: Float, size: Float, hx: Float, hy: Float, sat: Float)] = [:]
        for i in 0..<highWater where stage[i] != 0 {
            creatureEnergy += Double(energy[i])
            guard stage[i] == Stage.alive.rawValue else { continue }
            alive += 1
            let g = genes[i]
            if g.diet < 0.35 { herb += 1 } else if g.diet < 0.65 { omni += 1 } else { carn += 1 }
            sumSize += Double(g.size)
            sumSpeed += Double(g.speed)
            sumView += Double(g.viewDistance)
            sumConn += Double(connCount[i])
            sumGen += Double(generation[i])
            let sp = speciesOf[i]
            var e = acc[sp] ?? (0, 0, 0, 0, 0, 0)
            e.n += 1
            e.diet += g.diet
            e.size += g.size
            e.hx += cos(g.hue * 2 * .pi)
            e.hy += sin(g.hue * 2 * .pi)
            e.sat += g.saturation
            acc[sp] = e
        }
        for (sp, e) in acc where sp >= 0 && Int(sp) < species.count {
            let rec = species[Int(sp)]
            let n = Float(e.n)
            rec.meanDiet = e.diet / n
            rec.meanSize = e.size / n
            var h = atan2(e.hy, e.hx) / (2 * .pi)
            if h < 0 { h += 1 }
            rec.meanHue = h
            rec.meanSaturation = e.sat / n
        }
        if !firstCarnivoreReported {
            for (sp, e) in acc where e.n >= 15 && e.diet / Float(e.n) > 0.65 {
                firstCarnivoreReported = true
                log(.firstCarnivore, "初の肉食種「\(species[Int(sp)].name)」が現れた", sp)
                break
            }
        }
        while maxGeneration >= nextGenerationMilestone {
            log(.milestone, "第\(nextGenerationMilestone)世代に到達")
            switch nextGenerationMilestone {
            case 10: nextGenerationMilestone = 25
            case 25: nextGenerationMilestone = 50
            case 50: nextGenerationMilestone = 100
            default: nextGenerationMilestone += 100
            }
        }
        var plantE: Double = 0, meatE: Double = 0
        for k in 0..<foodCount {
            if foodKind[k] == 0 { plantE += Double(foodEnergy[k]) } else { meatE += Double(foodEnergy[k]) }
        }
        let a = Double(max(alive, 1))
        let creatureSeconds = window.creatureTicks / Double(config.ticksPerSecond)
        let intakeRate = creatureSeconds > 0 ? Float(Double(window.intake) / creatureSeconds) : 0
        let livingSpecies = species.reduce(Int32(0)) { $0 + ($1.isAlive && $1.population > 0 ? 1 : 0) }
        let s = StatSample(
            tick: tick,
            population: Int32(aliveCount), eggs: Int32(eggCount),
            herbivores: herb, omnivores: omni, carnivores: carn,
            species: livingSpecies,
            plants: Int32(plantCount),
            plantEnergy: Float(plantE), meatEnergy: Float(meatE), soilEnergy: soil,
            creatureEnergy: Float(creatureEnergy),
            meanSize: Float(sumSize / a), meanSpeed: Float(sumSpeed / a),
            meanViewDistance: Float(sumView / a), meanConnections: Float(sumConn / a),
            meanGeneration: Float(sumGen / a), maxGeneration: maxGeneration,
            intakeRate: intakeRate,
            secondsPerMeal: intakeRate > 0 ? config.plantEnergy / intakeRate : .infinity,
            births: window.births,
            deathsStarved: window.deathsStarved, deathsKilled: window.deathsKilled, deathsOld: window.deathsOld,
            meatIntakeShare: window.intake > 0 ? window.meatIntake / window.intake : 0)
        samples.append(s)
        window = StatWindow()
    }
}
