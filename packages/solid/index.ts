import { CliRenderer, createCliRenderer, engine, type CliRendererConfig } from "@opentui/core"
import { createTestRenderer, type TestRendererOptions } from "@opentui/core/testing"
import { getOwner } from "solid-js"
import type { JSX } from "./jsx-runtime"
import { RendererContext } from "./src/elements"
import { _render as renderInternal, createComponent, pushActiveRenderer, popActiveRenderer } from "./src/reconciler"
import { registerOwnerRenderer } from "./src/renderer-stack"

export const render = async (
  node: () => JSX.Element,
  rendererOrConfig: CliRenderer | CliRendererConfig = {},
): Promise<CliRenderer> => {
  let isDisposed = false
  let dispose: () => void

  const renderer =
    rendererOrConfig instanceof CliRenderer
      ? rendererOrConfig
      : await createCliRenderer({
          ...rendererOrConfig,
          onDestroy: () => {
            engine.detach(renderer)
            if (!isDisposed) {
              isDisposed = true
              dispose()
            }
            rendererOrConfig.onDestroy?.()
          },
        })

  if (rendererOrConfig instanceof CliRenderer) {
    renderer.on("destroy", () => {
      engine.detach(renderer)
      if (!isDisposed) {
        isDisposed = true
        dispose()
      }
    })
  }

  engine.attach(renderer)

  pushActiveRenderer(renderer)
  try {
    dispose = renderInternal(() => {
      const owner = getOwner()
      if (owner) registerOwnerRenderer(owner, renderer)
      return createComponent(RendererContext.Provider, {
        get value() {
          return renderer
        },
        get children() {
          return createComponent(node, {})
        },
      })
    }, renderer.root)
  } finally {
    popActiveRenderer()
  }

  return renderer
}

export const testRender = async (node: () => JSX.Element, renderConfig: TestRendererOptions = {}) => {
  let isDisposed = false
  const testSetup = await createTestRenderer({
    ...renderConfig,
    onDestroy: () => {
      engine.detach(testSetup.renderer)
      if (!isDisposed) {
        isDisposed = true
        dispose()
      }
      renderConfig.onDestroy?.()
    },
  })
  engine.attach(testSetup.renderer)

  pushActiveRenderer(testSetup.renderer)
  let dispose: () => void
  try {
    dispose = renderInternal(() => {
      const owner = getOwner()
      if (owner) registerOwnerRenderer(owner, testSetup.renderer)
      return createComponent(RendererContext.Provider, {
        get value() {
          return testSetup.renderer
        },
        get children() {
          return createComponent(node, {})
        },
      })
    }, testSetup.renderer.root)
  } finally {
    popActiveRenderer()
  }

  return testSetup
}

export * from "./src/reconciler"
export * from "./src/elements"
export * from "./src/types/elements"
export { type JSX }
