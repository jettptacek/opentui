import { test, expect, afterEach } from "bun:test"
import { createTestRenderer, type TestRenderer } from "../testing/test-renderer"
import { TextRenderable } from "../renderables/Text"
import { engine } from "../animation/Timeline"

const renderers: TestRenderer[] = []

afterEach(() => {
  for (const r of renderers) {
    r.destroy()
  }
  renderers.length = 0
  engine.clear()
})

function track(r: TestRenderer) {
  renderers.push(r)
  return r
}

test("two renderers can coexist independently", async () => {
  const setup1 = await createTestRenderer({ width: 40, height: 10 })
  const setup2 = await createTestRenderer({ width: 60, height: 20 })
  track(setup1.renderer)
  track(setup2.renderer)

  expect(setup1.renderer.width).toBe(40)
  expect(setup1.renderer.height).toBe(10)
  expect(setup2.renderer.width).toBe(60)
  expect(setup2.renderer.height).toBe(20)
})

test("each renderer has independent render buffers", async () => {
  const setup1 = await createTestRenderer({ width: 20, height: 5 })
  const setup2 = await createTestRenderer({ width: 20, height: 5 })
  track(setup1.renderer)
  track(setup2.renderer)

  const text1 = new TextRenderable(setup1.renderer, { id: "r1-text", content: "RENDERER_ONE" })
  setup1.renderer.root.add(text1)

  const text2 = new TextRenderable(setup2.renderer, { id: "r2-text", content: "RENDERER_TWO" })
  setup2.renderer.root.add(text2)

  await setup1.renderOnce()
  await setup2.renderOnce()

  const frame1 = setup1.captureCharFrame()
  const frame2 = setup2.captureCharFrame()

  expect(frame1).toContain("RENDERER_ONE")
  expect(frame1).not.toContain("RENDERER_TWO")
  expect(frame2).toContain("RENDERER_TWO")
  expect(frame2).not.toContain("RENDERER_ONE")
})

test("destroying one renderer does not affect the other", async () => {
  const setup1 = await createTestRenderer({ width: 20, height: 5 })
  const setup2 = await createTestRenderer({ width: 20, height: 5 })
  track(setup1.renderer)
  track(setup2.renderer)

  const text2 = new TextRenderable(setup2.renderer, { id: "r2-text", content: "STILL_ALIVE" })
  setup2.renderer.root.add(text2)

  // Destroy renderer1
  setup1.renderer.destroy()

  // renderer2 should still work
  await setup2.renderOnce()
  const frame = setup2.captureCharFrame()
  expect(frame).toContain("STILL_ALIVE")
})

test("timeline engine supports multiple renderers", async () => {
  const setup1 = await createTestRenderer({ width: 20, height: 5 })
  const setup2 = await createTestRenderer({ width: 20, height: 5 })
  track(setup1.renderer)
  track(setup2.renderer)

  engine.attach(setup1.renderer)
  engine.attach(setup2.renderer)

  // Both should be attached without error
  // Detaching one should not affect the other
  engine.detach(setup1.renderer)

  // Attaching again should work
  engine.attach(setup1.renderer)

  // Detach all
  engine.detach(setup1.renderer)
  engine.detach(setup2.renderer)
})
