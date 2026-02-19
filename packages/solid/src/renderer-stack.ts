// Shared renderer lookup for multi-renderer support.

import type { CliRenderer } from "@opentui/core"
import { getOwner } from "solid-js"


const rendererStack: CliRenderer[] = []

export function pushActiveRenderer(renderer: CliRenderer): void {
  rendererStack.push(renderer)
}

export function popActiveRenderer(): void {
  rendererStack.pop()
}

interface SolidOwner {
  owner: SolidOwner | null
  [key: string]: unknown
}

const ownerRendererMap = new WeakMap<object, CliRenderer>()

export function registerOwnerRenderer(owner: object, renderer: CliRenderer): void {
  ownerRendererMap.set(owner, renderer)
}

function findRendererFromOwner(): CliRenderer | undefined {
  let owner = getOwner() as SolidOwner | null
  let depth = 0
  while (owner) {
    const r = ownerRendererMap.get(owner)
    if (r) return r
    owner = owner.owner
    depth++
    if (depth > 100) break // safety
  }
  return undefined
}


export function getActiveRenderer(): CliRenderer | undefined {
  const stackRenderer = rendererStack[rendererStack.length - 1]
  if (stackRenderer) return stackRenderer
  return findRendererFromOwner()
}
