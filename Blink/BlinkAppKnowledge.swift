//
//  BlinkAppKnowledge.swift
//  Blink
//
//  Local knowledge base + lexical retrieval for design / creative apps
//  (Onshape, Blender, Adobe Photoshop, Adobe Illustrator, Figma, etc).
//  Used to ground voice answers when the user is focused on one of
//  these apps and asks a how-to question.
//
//  Storage: a static array of entries embedded as Swift literals so
//  there's no resource-bundling step. Retrieval: simple keyword
//  overlap with light TF weighting. Good enough for a hackathon demo
//  and replaceable with an embedding model later without touching
//  the call sites.
//

import Foundation

struct BlinkAppKnowledgeEntry {
    let id: String
    let app: String           // human label, e.g. "Onshape"
    let bundleIdHints: [String] // bundle IDs that should trigger this app's pool
    let appAliases: [String]  // names a user might say
    let title: String
    let body: String
    let tags: [String]
}

struct BlinkAppKnowledgeRetrieval {
    let entry: BlinkAppKnowledgeEntry
    let score: Double
}

enum BlinkAppKnowledgeStore {

    static let entries: [BlinkAppKnowledgeEntry] = [
        // MARK: - Onshape
        BlinkAppKnowledgeEntry(
            id: "onshape.sketch.start",
            app: "Onshape",
            bundleIdHints: ["com.onshape.app", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["onshape", "on shape"],
            title: "Starting a sketch on a plane",
            body: "Pick a plane in the feature tree (Top, Front, or Right), then click the Sketch tool in the toolbar. Once you're in sketch mode, use Line, Rectangle, Circle, or Spline to draw your profile. Press Escape or click the green check to exit the sketch.",
            tags: ["sketch", "plane", "draw", "profile", "start"]
        ),
        BlinkAppKnowledgeEntry(
            id: "onshape.extrude",
            app: "Onshape",
            bundleIdHints: ["com.onshape.app", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["onshape"],
            title: "Extruding a sketch into a solid",
            body: "Select a closed sketch region, then click the Extrude tool in the toolbar. Set a depth, choose Blind, Through All, or Up To Face, and pick whether to add, subtract, or intersect with existing geometry. Hit the green check to commit.",
            tags: ["extrude", "solid", "depth", "feature"]
        ),
        BlinkAppKnowledgeEntry(
            id: "onshape.fillet",
            app: "Onshape",
            bundleIdHints: ["com.onshape.app", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["onshape"],
            title: "Adding fillets to edges",
            body: "Click the Fillet tool, then select one or more edges or faces. Type a radius in the dialog. For uneven fillets, use the Variable option. Equal-radius fillets are cheaper to compute and rebuild faster.",
            tags: ["fillet", "round", "edge", "radius"]
        ),
        BlinkAppKnowledgeEntry(
            id: "onshape.assembly.mate",
            app: "Onshape",
            bundleIdHints: ["com.onshape.app", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["onshape"],
            title: "Mating parts in an assembly",
            body: "Insert parts with the Insert tool. Then use Fastened, Revolute, Slider, Cylindrical, or Ball mates to constrain them. Pick a mate connector on each part — Onshape uses connectors instead of raw face/edge picks, which keeps mates stable when geometry changes.",
            tags: ["assembly", "mate", "connector", "constraint"]
        ),
        BlinkAppKnowledgeEntry(
            id: "onshape.configurations",
            app: "Onshape",
            bundleIdHints: ["com.onshape.app", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["onshape"],
            title: "Using configurations for part variants",
            body: "Open the Configurations panel and add a configuration variable. Drive feature parameters (depths, counts, on/off) from the variable. Switching configurations regenerates the part in place — useful for sizes, holes patterns, or material variants.",
            tags: ["configuration", "variant", "parameter", "variable"]
        ),
        BlinkAppKnowledgeEntry(
            id: "onshape.drawings",
            app: "Onshape",
            bundleIdHints: ["com.onshape.app", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["onshape"],
            title: "Creating a drawing from a part",
            body: "Right-click the part in the tab bar and choose Create Drawing of <part>. Pick a template and sheet size. Drag views from the View tool onto the sheet. Add dimensions with the Dimension tool — Onshape will pull associative dimensions tied to features.",
            tags: ["drawing", "drafting", "view", "dimension"]
        ),
        BlinkAppKnowledgeEntry(
            id: "onshape.featurescript",
            app: "Onshape",
            bundleIdHints: ["com.onshape.app", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["onshape"],
            title: "Writing a FeatureScript custom feature",
            body: "Create a FeatureScript document with New > FeatureScript. Define a feature with `annotation { \"Feature Type Name\" : \"...\" }` and a `precondition` block for inputs. Inside the body, manipulate parts with built-in functions like `opExtrude`, `opFillet`, or `opBoolean`. Publish the feature to use it from a Part Studio.",
            tags: ["featurescript", "custom", "script", "automation"]
        ),

        // MARK: - Blender
        BlinkAppKnowledgeEntry(
            id: "blender.modes",
            app: "Blender",
            bundleIdHints: ["org.blenderfoundation.blender"],
            appAliases: ["blender"],
            title: "Switching between Object and Edit modes",
            body: "Tab toggles between Object Mode and Edit Mode for the selected object. Edit Mode exposes vertices, edges, and faces; press 1, 2, or 3 to pick which selection type. Object Mode is for moving and parenting whole objects.",
            tags: ["mode", "edit", "object", "tab"]
        ),
        BlinkAppKnowledgeEntry(
            id: "blender.modifiers",
            app: "Blender",
            bundleIdHints: ["org.blenderfoundation.blender"],
            appAliases: ["blender"],
            title: "Adding a modifier",
            body: "In the Properties editor, click the wrench icon for the Modifier tab, then Add Modifier. Subdivision Surface smooths geometry, Boolean does cut/join with another object, Mirror duplicates across an axis, Array repeats with offset. Order in the stack matters — modifiers apply top to bottom.",
            tags: ["modifier", "subdivision", "boolean", "mirror", "array", "stack"]
        ),
        BlinkAppKnowledgeEntry(
            id: "blender.shading",
            app: "Blender",
            bundleIdHints: ["org.blenderfoundation.blender"],
            appAliases: ["blender"],
            title: "Setting up materials in the Shader Editor",
            body: "Switch a workspace to Shading. Add a new material on the active object. The Principled BSDF node is the default — drive Base Color, Roughness, Metallic, and Normal inputs from Image Texture nodes for PBR. Use the Mapping + Texture Coordinate nodes to control UVs.",
            tags: ["material", "shader", "pbr", "principled", "texture"]
        ),
        BlinkAppKnowledgeEntry(
            id: "blender.sculpt",
            app: "Blender",
            bundleIdHints: ["org.blenderfoundation.blender"],
            appAliases: ["blender"],
            title: "Sculpt mode brushes",
            body: "Enter Sculpt Mode from the mode dropdown. Press X for the Draw brush, S for Smooth, G for Grab, I for Inflate, P for Pinch, C for Crease. Hold Shift to temporarily smooth, hold Ctrl to invert the brush. Add a Multiresolution modifier to sculpt at higher detail without committing geometry.",
            tags: ["sculpt", "brush", "draw", "smooth", "grab", "multires"]
        ),
        BlinkAppKnowledgeEntry(
            id: "blender.uv",
            app: "Blender",
            bundleIdHints: ["org.blenderfoundation.blender"],
            appAliases: ["blender"],
            title: "Unwrapping UVs",
            body: "In Edit Mode, mark seams along edges you want to split (Edge select, then Edge > Mark Seam). Select all faces, then U > Unwrap. Open the UV editor to check the layout; use Smart UV Project for a quick pass without seams.",
            tags: ["uv", "unwrap", "seam", "texture"]
        ),
        BlinkAppKnowledgeEntry(
            id: "blender.render",
            app: "Blender",
            bundleIdHints: ["org.blenderfoundation.blender"],
            appAliases: ["blender"],
            title: "Rendering with Cycles vs Eevee",
            body: "In Render Properties, pick Cycles for physically-based path-traced renders (slower, more realistic) or Eevee for real-time rasterization (faster, less accurate). For Cycles, enable GPU compute under Preferences > System for big speedups. Set Samples lower for previews and higher for finals.",
            tags: ["render", "cycles", "eevee", "samples", "gpu"]
        ),
        BlinkAppKnowledgeEntry(
            id: "blender.geonodes",
            app: "Blender",
            bundleIdHints: ["org.blenderfoundation.blender"],
            appAliases: ["blender"],
            title: "Geometry Nodes basics",
            body: "Add a Geometry Nodes modifier. Open the Geometry Nodes workspace. The default tree has Group Input (the mesh) and Group Output. Insert nodes like Distribute Points on Faces, Instance on Points, and Set Position to scatter geometry procedurally without committing real mesh data.",
            tags: ["geometry nodes", "procedural", "scatter", "instance"]
        ),

        // MARK: - Adobe Photoshop
        BlinkAppKnowledgeEntry(
            id: "photoshop.layer.mask",
            app: "Adobe Photoshop",
            bundleIdHints: ["com.adobe.Photoshop", "com.adobe.photoshop"],
            appAliases: ["photoshop", "ps"],
            title: "Adding a layer mask",
            body: "Select a layer and click the rectangle-with-circle icon at the bottom of the Layers panel. Paint with black to hide pixels, white to reveal. Alt-click the mask thumbnail to view the mask itself. Shift-click to disable, Ctrl/Cmd-click to load the mask as a selection.",
            tags: ["mask", "layer", "hide", "reveal", "paint"]
        ),
        BlinkAppKnowledgeEntry(
            id: "photoshop.adjustment",
            app: "Adobe Photoshop",
            bundleIdHints: ["com.adobe.Photoshop", "com.adobe.photoshop"],
            appAliases: ["photoshop", "ps"],
            title: "Using non-destructive adjustment layers",
            body: "Click the half-filled circle icon in the Layers panel and pick Curves, Levels, Hue/Saturation, or Color Balance. The adjustment is a layer — you can re-edit it, mask it, or delete it without touching the pixel layer below. Clip an adjustment (Alt-click between layers) to limit it to the layer directly under it.",
            tags: ["adjustment", "curves", "levels", "non-destructive", "clipping"]
        ),
        BlinkAppKnowledgeEntry(
            id: "photoshop.select.subject",
            app: "Adobe Photoshop",
            bundleIdHints: ["com.adobe.Photoshop", "com.adobe.photoshop"],
            appAliases: ["photoshop", "ps"],
            title: "Selecting the subject of a photo",
            body: "Choose Select > Subject for a one-click AI-based selection. Refine with Select > Select and Mask: tweak Smart Radius for fuzzy edges like hair, and output to a layer mask. For trickier subjects, the Object Selection tool lets you draw a rectangle around just one object.",
            tags: ["select", "subject", "mask", "hair", "ai"]
        ),
        BlinkAppKnowledgeEntry(
            id: "photoshop.smart.object",
            app: "Adobe Photoshop",
            bundleIdHints: ["com.adobe.Photoshop", "com.adobe.photoshop"],
            appAliases: ["photoshop", "ps"],
            title: "Converting a layer to a Smart Object",
            body: "Right-click the layer in the Layers panel and choose Convert to Smart Object. Transforms (scale, rotate, warp) and filters become non-destructive — double-click the Smart Object thumbnail to edit the source. Useful for keeping raw resolution when you scale a layer down then back up.",
            tags: ["smart object", "non-destructive", "filter", "transform"]
        ),
        BlinkAppKnowledgeEntry(
            id: "photoshop.generative.fill",
            app: "Adobe Photoshop",
            bundleIdHints: ["com.adobe.Photoshop", "com.adobe.photoshop"],
            appAliases: ["photoshop", "ps"],
            title: "Generative Fill",
            body: "Make a selection where you want new content (or empty space to extend the canvas). The Contextual Task Bar shows Generative Fill — leave the prompt blank to remove the selection, or type a short prompt to add something. Each generation lives on its own generative layer so you can swap variations.",
            tags: ["generative fill", "ai", "extend", "remove", "firefly"]
        ),
        BlinkAppKnowledgeEntry(
            id: "photoshop.camera.raw",
            app: "Adobe Photoshop",
            bundleIdHints: ["com.adobe.Photoshop", "com.adobe.photoshop"],
            appAliases: ["photoshop", "ps"],
            title: "Opening a layer in Camera Raw",
            body: "Convert the layer to a Smart Object first (so the edit stays non-destructive), then Filter > Camera Raw Filter. You get the full Lightroom-style develop panel: Exposure, Highlights, Shadows, Whites/Blacks, Texture, Clarity, Dehaze, plus color grading and masking. Double-click later to re-edit.",
            tags: ["camera raw", "develop", "exposure", "filter", "smart object"]
        ),

        // MARK: - Adobe Illustrator
        BlinkAppKnowledgeEntry(
            id: "illustrator.pen.tool",
            app: "Adobe Illustrator",
            bundleIdHints: ["com.adobe.illustrator", "com.adobe.Illustrator"],
            appAliases: ["illustrator", "ai", "adobe illustrator"],
            title: "Drawing with the Pen tool",
            body: "Press P for the Pen tool. Click to drop straight-line anchors, click and drag to drop a curve handle. Hold Alt while dragging from an existing anchor to break the handle and make a sharp corner. Switch to the Direct Selection tool (A) to nudge individual anchors or handles after the path is closed.",
            tags: ["pen", "anchor", "curve", "bezier"]
        ),
        BlinkAppKnowledgeEntry(
            id: "illustrator.pathfinder",
            app: "Adobe Illustrator",
            bundleIdHints: ["com.adobe.illustrator", "com.adobe.Illustrator"],
            appAliases: ["illustrator"],
            title: "Combining shapes with the Pathfinder panel",
            body: "Window > Pathfinder. Select two or more overlapping shapes, then click Unite to merge, Minus Front to cut, Intersect to keep overlap, or Exclude to keep non-overlapping areas. Alt-click for a non-destructive compound shape that you can release later.",
            tags: ["pathfinder", "unite", "boolean", "shape"]
        ),
        BlinkAppKnowledgeEntry(
            id: "illustrator.live.shapes",
            app: "Adobe Illustrator",
            bundleIdHints: ["com.adobe.illustrator", "com.adobe.Illustrator"],
            appAliases: ["illustrator"],
            title: "Editing Live Shapes",
            body: "Rectangles, ellipses, and polygons stay editable — drag the small widgets on the bounding box to round corners individually, change the number of sides of a polygon, or rotate. Window > Transform exposes the same controls numerically. Object > Shape > Expand Shape locks them into plain paths when you're done.",
            tags: ["live shape", "rectangle", "ellipse", "corner", "polygon"]
        ),
        BlinkAppKnowledgeEntry(
            id: "illustrator.type.on.path",
            app: "Adobe Illustrator",
            bundleIdHints: ["com.adobe.illustrator", "com.adobe.Illustrator"],
            appAliases: ["illustrator"],
            title: "Putting text on a path",
            body: "Draw any open or closed path. Pick the Type on a Path tool (long-press the Type tool to see variants), then click on the path. Type your text — it flows along the curve. Drag the start, end, or center brackets to move the text along, flip it, or reposition.",
            tags: ["type", "text", "path", "curve"]
        ),
        BlinkAppKnowledgeEntry(
            id: "illustrator.export.svg",
            app: "Adobe Illustrator",
            bundleIdHints: ["com.adobe.illustrator", "com.adobe.Illustrator"],
            appAliases: ["illustrator"],
            title: "Exporting a clean SVG",
            body: "File > Export > Export As, pick SVG. In the dialog, set Styling to Inline Style, Font to SVG, and Decimal to 2 or 3. Check Minify and Responsive for the smallest file size. Use Export for Screens (Cmd+Alt+E) to batch out multiple artboards as separate SVGs at once.",
            tags: ["export", "svg", "web", "artboard"]
        ),

        // MARK: - Figma
        BlinkAppKnowledgeEntry(
            id: "figma.auto.layout",
            app: "Figma",
            bundleIdHints: ["com.figma.Desktop", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["figma"],
            title: "Adding Auto Layout to a frame",
            body: "Select a frame and press Shift+A, or pick Auto Layout in the right panel. Auto Layout reflows children when they resize or you add/remove items. Set direction (vertical/horizontal), spacing, padding, and alignment. Use 'Hug contents' for the frame to size to its children, or 'Fill container' for children to stretch.",
            tags: ["auto layout", "frame", "spacing", "responsive"]
        ),
        BlinkAppKnowledgeEntry(
            id: "figma.components.variants",
            app: "Figma",
            bundleIdHints: ["com.figma.Desktop", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["figma"],
            title: "Creating components and variants",
            body: "Select a frame and press Cmd+Alt+K to make a component (purple diamond). Drop the component anywhere as an instance — instances inherit from the main. Combine multiple components as Variants to expose properties like size, state, or icon position in the right panel. Edit the main once, all instances update.",
            tags: ["component", "variant", "instance", "design system"]
        ),
        BlinkAppKnowledgeEntry(
            id: "figma.constraints",
            app: "Figma",
            bundleIdHints: ["com.figma.Desktop", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["figma"],
            title: "Setting layout constraints inside a frame",
            body: "Select a child inside a non-Auto-Layout frame. In the right panel, the Constraints square shows horizontal and vertical pinning. Pick Left, Right, Center, Left and Right (stretch), or Scale. When the frame resizes, the child follows the constraint instead of staying at fixed coordinates.",
            tags: ["constraints", "frame", "responsive", "pin"]
        ),
        BlinkAppKnowledgeEntry(
            id: "figma.prototyping",
            app: "Figma",
            bundleIdHints: ["com.figma.Desktop", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["figma"],
            title: "Prototyping with interactions",
            body: "Switch to the Prototype tab on the right. Select an object or frame and drag the blue dot to a target frame. Pick a trigger (On Click, While Hovering, On Drag) and an action (Navigate To, Open Overlay, Smart Animate). Press Cmd+Alt+Enter or click the play icon to preview.",
            tags: ["prototype", "interaction", "smart animate", "overlay"]
        ),
        BlinkAppKnowledgeEntry(
            id: "figma.variables",
            app: "Figma",
            bundleIdHints: ["com.figma.Desktop", "com.google.Chrome", "com.apple.Safari"],
            appAliases: ["figma"],
            title: "Using variables for tokens and modes",
            body: "Open Local Variables from the right panel. Create collections (Colors, Spacing, Typography) and add variables with values. Add modes (Light, Dark) to swap entire value sets. Bind variables to fills, strokes, and Auto Layout spacing by clicking the small hexagon next to the property.",
            tags: ["variable", "token", "mode", "dark mode", "design system"]
        ),
    ]

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "in", "to", "for", "on",
        "at", "with", "by", "is", "are", "was", "were", "do", "does",
        "did", "how", "what", "where", "when", "why", "i", "you", "my",
        "we", "us", "it", "this", "that", "these", "those", "can",
        "could", "should", "would", "may", "might", "shall", "will",
        "be", "been", "being", "have", "has", "had", "having", "from",
        "as", "if", "than", "then", "so", "but", "not", "no", "yes",
        "please", "thanks", "okay", "ok", "hey", "hi", "hello"
    ]

    private static func tokens(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) }
    }

    /// Returns the bundle IDs of the apps Blink has knowledge for.
    /// Useful to decide whether to even bother running retrieval.
    static var supportedBundleIDs: Set<String> {
        Set(entries.flatMap { $0.bundleIdHints })
    }

    /// Retrieves up to `limit` entries best matching `query`. Optionally
    /// restricts to entries tagged with the focused app's bundle ID or
    /// the focused app's display name. Returns sorted by descending
    /// score; entries that match zero query tokens are dropped.
    static func retrieve(
        query: String,
        focusedAppBundleID: String? = nil,
        focusedAppName: String? = nil,
        limit: Int = 3
    ) -> [BlinkAppKnowledgeRetrieval] {
        let queryTokens = tokens(from: query)
        guard !queryTokens.isEmpty else { return [] }

        let focusedBundleLower = focusedAppBundleID?.lowercased()
        let focusedNameLower = focusedAppName?.lowercased()

        let scored: [BlinkAppKnowledgeRetrieval] = entries.compactMap { entry in
            let entryTokens = Set(
                tokens(from: entry.title)
                + tokens(from: entry.body)
                + entry.tags.flatMap { tokens(from: $0) }
                + entry.appAliases.flatMap { tokens(from: $0) }
            )
            var overlap = 0
            for token in queryTokens where entryTokens.contains(token) {
                overlap += 1
            }
            guard overlap > 0 else { return nil }

            // Base score: query coverage.
            var score = Double(overlap) / Double(queryTokens.count)

            // Heavy boost when the focused app matches a bundle hint.
            if let focusedBundleLower {
                if entry.bundleIdHints.map({ $0.lowercased() }).contains(focusedBundleLower) {
                    score += 2.0
                }
            }
            // Mild boost when the user named the app in the query.
            for alias in entry.appAliases where queryTokens.contains(alias.lowercased()) {
                score += 1.0
            }
            // Boost when the focused app name matches (e.g., "Onshape")
            // — covers the browser-based Onshape/Figma case where the
            // bundle ID is Chrome but the window title says Onshape.
            if let focusedNameLower {
                if entry.appAliases.map({ $0.lowercased() }).contains(focusedNameLower) {
                    score += 1.5
                }
            }

            return BlinkAppKnowledgeRetrieval(entry: entry, score: score)
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Formats top-K retrieval results as a system-prompt-ready block.
    /// Returns an empty string when nothing matches so the caller can
    /// drop the prefix cleanly.
    static func promptContext(
        for query: String,
        focusedAppBundleID: String? = nil,
        focusedAppName: String? = nil,
        limit: Int = 3
    ) -> String {
        let results = retrieve(
            query: query,
            focusedAppBundleID: focusedAppBundleID,
            focusedAppName: focusedAppName,
            limit: limit
        )
        return format(results: results)
    }

    /// Async variant: tries the HF-embedding semantic index first with a
    /// short timeout (so voice latency stays bounded), then falls back
    /// to lexical retrieval. Use this from any async context.
    static func promptContextAsync(
        for query: String,
        focusedAppBundleID: String? = nil,
        focusedAppName: String? = nil,
        limit: Int = 3,
        semanticTimeout: Duration = .milliseconds(1200)
    ) async -> String {
        let semanticResults = await withTimeout(semanticTimeout) {
            await BlinkSemanticIndex.shared.retrieve(
                query: query,
                focusedAppBundleID: focusedAppBundleID,
                focusedAppName: focusedAppName,
                limit: limit
            )
        } ?? []

        if !semanticResults.isEmpty {
            return format(results: semanticResults)
        }

        return promptContext(
            for: query,
            focusedAppBundleID: focusedAppBundleID,
            focusedAppName: focusedAppName,
            limit: limit
        )
    }

    private static func format(results: [BlinkAppKnowledgeRetrieval]) -> String {
        guard !results.isEmpty else { return "" }
        var lines: [String] = [
            "relevant app knowledge (use this if the user's question maps to it; otherwise ignore):"
        ]
        for result in results {
            lines.append("- [\(result.entry.app)] \(result.entry.title): \(result.entry.body)")
        }
        return lines.joined(separator: "\n")
    }

    private static func withTimeout<T>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
