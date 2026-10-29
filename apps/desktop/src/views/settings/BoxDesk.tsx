import clsx from 'clsx'
import { useEffect, useState } from 'react'

import { deskOpenDelay } from './boxDeskModel'

import './BoxDesk.css'

import type { DeskModel } from './boxDeskModel'
import type { ReactNode } from 'react'

// Every machine on the page shares one opening, however many there are and whenever each appears.
const openingWave = { at: -Infinity }

// A laptop keyboard's rows in key widths: the half-height function row, then the letters down
// to the space bar. 0 marks the inverted-T arrow keys.
const KEY_ROWS = [
  [1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
  [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.5],
  [1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
  [1.75, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.75],
  [2.25, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2.25],
  [1, 1, 1, 1.25, 5, 1.25, 1, 0],
]

function Keyboard() {
  return (
    <div className="desk-keys">
      {KEY_ROWS.map((row, r) => (
        <div key={r} className="desk-keyrow">
          {row.map((width, k) =>
            width ? (
              <i key={k} className="desk-key" style={{ flexGrow: width }} />
            ) : (
              <span key={k} className="desk-arrows">
                <i className="desk-key" />
                <i className="desk-key" />
                <i className="desk-key" />
                <i className="desk-key" />
              </span>
            ),
          )}
        </div>
      ))}
    </div>
  )
}

/** 云端电脑使用 MuseAgent 标志。 */
function Mark({ brand }: { brand: DeskModel['brand'] }) {
  if (brand !== 'nuphos') return null

  return (
    <svg className="desk-mark is-nuphos" viewBox="24 32 80 64" aria-hidden>
      <path d="M24 96V32H38L64 67L90 32H104V96H88V59L64 91L40 59V96Z" />
    </svg>
  )
}

/** Folded shut under the viewer; the lid swings up as the view turns to face it. */
function Laptop({ brand, screen }: { brand: DeskModel['brand']; screen: ReactNode }) {
  return (
    <>
      <div className="desk-deck">
        <Keyboard />
        <i className="desk-pad" />
        <i className="desk-edge" />
      </div>
      <div className="desk-lid">
        <div className="desk-face desk-outer">
          <Mark brand={brand} />
        </div>
        <div className="desk-face desk-inner">
          <div className="desk-glass">
            {screen}
            <i className={brand === 'apple' ? 'desk-notch' : 'desk-cam'} />
          </div>
          <i className="desk-hinge" />
        </div>
      </div>
    </>
  )
}

/** A Mac mini or a Box: its top from above, then its front as the view turns. */
function MiniBox({ brand }: { brand: DeskModel['brand'] }) {
  return (
    <>
      <i className="desk-mini-shadow" />
      <div className="desk-mini">
        <Mark brand={brand} />
        <div className="desk-mini-front">
          <i className="desk-mini-port" />
          <i className="desk-mini-port" />
          <i className="desk-mini-jack" />
        </div>
      </div>
    </>
  )
}

/** Every machine starts seen from above; once the page shows it, the view turns to face it. Each
 * stands in the same space on the same baseline. A laptop shows its readings on its screen; a box
 * shows them in a card beside it, inside the same space, never over the machine. */
export function DeskArt({
  model,
  on,
  children,
}: {
  model: DeskModel
  /** A paused or unreachable machine keeps a dark screen and an unlit power light, and no readings. */
  on: boolean
  /** The machine's readings and agents. */
  children: ReactNode
}) {
  const [open, setOpen] = useState(false)

  useEffect(() => {
    const timer = window.setTimeout(
      () => setOpen(true),
      deskOpenDelay(performance.now(), openingWave),
    )

    return () => window.clearTimeout(timer)
  }, [])

  const laptop = model.form === 'laptop'
  // Nothing on it can be reached until it has turned to face the viewer.
  const panel = (className: string) => (
    <div className={className} inert={!open}>
      {children}
    </div>
  )
  const screen = (
    <div className={clsx('desk-screen', !on && 'is-off')}>
      {on && <i className="desk-wallpaper" />}
      {on && panel('desk-panel is-screen')}
    </div>
  )

  return (
    <div
      className={clsx(
        'desk-art',
        `desk-${model.form}`,
        `is-${model.brand}`,
        open && 'is-open',
        !on && 'is-off',
      )}
    >
      <div className="desk-rig" aria-hidden={laptop ? !on : true}>
        {laptop ? <Laptop brand={model.brand} screen={screen} /> : <MiniBox brand={model.brand} />}
      </div>
      {!laptop && on && panel('desk-panel desk-side')}
    </div>
  )
}
