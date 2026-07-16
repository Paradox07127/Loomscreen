#if !LITE_BUILD
    extension WPESceneScriptInstanceInventory {
        init(document: WPESceneDocument) {
            let text = document.textObjects.reduce(into: 0) { count, object in
                if object.textScript != nil {
                    count += 1
                }
            }
            let layer = document.scriptHostObjects.count
                + document.imageObjects.reduce(into: 0) { count, object in
                    if object.visibleScript != nil {
                        count += 1
                    }
                    if object.alphaScript != nil {
                        count += 1
                    }
                }
                + document.textObjects.reduce(into: 0) { count, object in
                    if object.visibleScript != nil {
                        count += 1
                    }
                    if object.alphaScript != nil {
                        count += 1
                    }
                }
            let transform = document.imageObjects.reduce(into: 0) { count, object in
                if object.originScript != nil {
                    count += 1
                }
                if object.scaleScript != nil {
                    count += 1
                }
                if object.anglesScript != nil {
                    count += 1
                }
            } + document.transformHostObjects.reduce(into: 0) { count, object in
                if object.originScript != nil {
                    count += 1
                }
                if object.scaleScript != nil {
                    count += 1
                }
                if object.anglesScript != nil {
                    count += 1
                }
            } + document.textObjects.reduce(into: 0) { count, object in
                if object.originScript != nil {
                    count += 1
                }
            }
            self.init(text: text, layer: layer, transform: transform)
        }
    }
#endif
