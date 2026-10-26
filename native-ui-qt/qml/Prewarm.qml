// Pre-"cottura" degli shader all'avvio, dietro lo splash.
//
// Su vc4 (Pi3, GLES2) la compilazione di un programma shader avviene al PRIMO
// disegno di quel materiale: la prima volta che si apre una schermata, Qt
// compila al volo le sue pipeline (misurato ~0,7 s complessivi, "pipeline
// creation"), e si vede lo scatto. Qui disegniamo una volta sola, su 4 px quasi
// trasparenti nell'angolo (coperti dalla UI che sta caricando, mai visibili),
// un'istanza minima di OGNI pipeline pesante, cosi' il programma GL viene
// compilato ADESSO, mentre lo splash e' ancora su, e non alla prima
// navigazione. Il backend GL cache-a il programma per sorgente dello shader
// (non per blend/stato), quindi una quad minima basta a scaldarlo.
//
// Appena fatti qualche fotogramma (le pipeline sono compilate), ci
// distruggiamo: la pipeline resta nella cache del render context per tutta la
// sessione anche dopo che l'elemento sparisce, quindi dopo non costiamo nulla
// (niente FBO, niente lavoro per fotogramma). Ogni effetto ha la SUA sorgente:
// due MultiEffect sulla stessa sorgente darebbero conflitto e la seconda
// pipeline non verrebbe disegnata (ne' compilata).
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes

Item {
    id: root
    width: 4; height: 4
    // > 0 cosi' lo scene graph NON ci scarta (opacity 0 = sottoalbero saltato =
    // niente disegno = niente compilazione); con l'opacita' il sottoalbero e'
    // disegnato in blending, come le copertine/sfondi veri.
    opacity: 0.004
    enabled: false            // mai un bersaglio della navigazione spaziale
    z: -1000                  // dietro tutto (comunque coperto dalla UI)

    component Tex: Rectangle {
        width: 4; height: 4
        gradient: Gradient {
            GradientStop { position: 0; color: "#808080" }
            GradientStop { position: 1; color: "#404040" }
        }
        layer.enabled: true
    }

    // 1) maschera ad angoli tondi (ShaderImage / Cover / tessere libreria): la
    //    pipeline MultiEffect piu' usata.
    Tex { id: maskBase }
    Rectangle { id: maskShape; width: 4; height: 4; radius: 2; color: "white"; layer.enabled: true }
    MultiEffect {
        source: maskBase; width: 4; height: 4
        maskEnabled: true; maskSource: maskShape
    }
    // 2) sfondo sfocato a tutto schermo (NowPlaying, MiniPlayer). blurMax e' un
    //    uniform, non cambia shader: una sola istanza copre 16/40/60.
    Tex { id: blurBase }
    MultiEffect {
        source: blurBase; width: 4; height: 4
        blurEnabled: true; blur: 1.0; blurMax: 40
    }
    // 3) bake di uno strato RGB opaco (lo staticLayer di NowPlaying) — scalda
    //    anche ShaderEffectSource.
    Item {
        width: 4; height: 4
        layer.enabled: true
        layer.format: ShaderEffectSource.RGB
        Rectangle { anchors.fill: parent; color: "#303030" }
    }
    // 4) Shape con CurveRenderer + gradiente radiale (Glow / anello di focus).
    Shape {
        width: 4; height: 4
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: 2; centerY: 2; centerRadius: 2; focalX: 2; focalY: 2
                GradientStop { position: 0; color: "#80d4af37" }
                GradientStop { position: 1; color: "#00d4af37" }
            }
            PathAngleArc { centerX: 2; centerY: 2; radiusX: 2; radiusY: 2; startAngle: 0; sweepAngle: 360 }
        }
    }

    // FrameAnimation tick-a solo quando un fotogramma e' stato DAVVERO prodotto:
    // dopo qualche fotogramma le pipeline sono compilate, quindi ci smontiamo.
    property int framesDone: 0
    FrameAnimation {
        running: true
        onTriggered: {
            root.framesDone += 1
            if (root.framesDone >= 3) { running = false; root.destroy() }
        }
    }
}
