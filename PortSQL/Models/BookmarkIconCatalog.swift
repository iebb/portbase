import Foundation

struct BookmarkIconCatalog {
    private static let catalog: [String] = [
        "server.rack", "externaldrive.fill", "internaldrive.fill", "opticaldiscdrive.fill",
        "memorychip.fill", "cpu.fill", "network", "network.badge.shield.half.filled", "network.badge.shield.half.filled",
        "cable.connector", "wifi.router.fill", "antenna.radiowaves.left.and.right", "globe", "globe.americas.fill",
        "globe.europe.africa.fill", "globe.asia.australia.fill", "sparkles.rectangle.stack", "terminal.fill", "apple.terminal.fill",
        "chevron.left.forwardslash.chevron.right", "curlybraces.square.fill", "doc.text.fill", "doc.richtext.fill", "doc.badge.gearshape.fill",
        "doc.badge.ellipsis", "folder.fill", "folder.badge.gearshape", "folder.badge.person.crop", "tray.full.fill",
        "archivebox.fill", "shippingbox.fill", "shippingbox.circle.fill", "shippingbox.and.arrow.backward.fill",
        "books.vertical.fill", "book.fill", "bookmark.fill", "bookmark.circle.fill", "star.fill",
        "star.square.fill", "bolt.fill", "bolt.circle.fill", "flashlight.on.fill", "shield.fill",
        "shield.lefthalf.filled", "lock.shield.fill", "key.fill", "key.horizontal.fill", "person.text.rectangle.fill",
        "person.crop.square.fill", "person.2.fill", "building.2.fill", "building.columns.fill", "briefcase.fill",
        "chart.bar.fill", "chart.bar.doc.horizontal.fill", "chart.line.uptrend.xyaxis", "chart.pie.fill", "waveform.path.ecg.rectangle.fill",
        "tablecells.fill", "tablecells.badge.ellipsis", "rectangle.grid.2x2.fill", "square.grid.3x3.fill", "list.bullet.rectangle.portrait.fill",
        "list.clipboard.fill", "square.and.pencil", "pencil.and.list.clipboard", "wand.and.stars", "magnifyingglass",
        "eyeglasses", "scope", "binoculars.fill", "camera.macro", "camera.filters",
        "paintbrush.fill", "paintpalette.fill", "swatchpalette.fill", "drop.fill", "circle.hexagongrid.fill",
        "hexagon.fill", "diamond.fill", "triangle.fill", "seal.fill", "capsule.portrait.fill",
        "cube.fill", "shippingbox.circle", "lanyardcard.fill", "creditcard.fill", "wallet.pass.fill",
        "ticket.fill", "tag.fill", "tag.circle.fill", "flag.fill", "bell.fill",
        "megaphone.fill", "paperplane.fill", "envelope.fill", "message.fill", "bubble.left.and.text.bubble.right.fill",
        "phone.fill", "video.fill", "headphones", "mic.fill", "speaker.wave.3.fill",
        "music.note.list", "play.rectangle.fill", "film.fill", "gamecontroller.fill", "puzzlepiece.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill", "slider.horizontal.3", "dial.high.fill",
        "gauge.with.needle.fill", "speedometer", "stopwatch.fill", "clock.fill", "calendar.circle.fill",
        "map.fill", "mappin.circle.fill", "location.circle.fill", "safari.fill", "airplane.circle.fill",
        "car.fill", "tram.fill", "ferry.fill", "figure.walk.circle.fill", "leaf.fill",
        "flame.fill", "snowflake", "cloud.fill", "sun.max.fill", "moon.fill",
        "camera.fill", "photo.fill", "photo.stack.fill", "scribble.variable",
        "brain.head.profile", "atom", "cross.case.fill", "stethoscope.circle.fill", "bandage.fill",
        "pawprint.fill", "tortoise.fill", "hare.fill", "fish.fill", "ladybug.fill",
        "tree.fill", "carrot.fill", "cup.and.saucer.fill", "fork.knife.circle.fill", "birthday.cake.fill"
    ]

    static let names: [String] = {
        var seen = Set<String>()
        return catalog.filter { seen.insert($0).inserted }
    }()

    static func defaultName(for engine: DatabaseEngine) -> String {
        engine.symbolName
    }
}
