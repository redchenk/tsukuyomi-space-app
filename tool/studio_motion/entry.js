import { createLive2DPerformanceBrain } from '../../third_party/yachiyo-live2d-studio/src/frontend/services/room/live2dPerformanceBrain.js';
import { sampleCubismBehaviorFrame } from '../../third_party/yachiyo-live2d-studio/src/frontend/services/room/live2dCubismBehaviorBridge.js';
import { compileBehaviorIntent } from '../../third_party/yachiyo-live2d-studio/src/frontend/services/room/live2dBehaviorController.js';

// This realm has no browser, storage, filesystem, network or native host callbacks.
// Only the active animation clock advances it, including through pause/resume.
let now = 1000, seed = 1, brain, manual = [], manualAt = 0, pulse = null;
globalThis.performance = { now: () => now };
Date.now = () => now;
Math.random = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return (seed >>> 0) / 4294967296; };
function reset(value) {
  seed = (Number(value) >>> 0) || 1;
  brain = createLive2DPerformanceBrain(); manual = []; pulse = null;
}
function frame(mouth) {
  brain.onMouth(mouth, now);
  const performanceFrame = brain.sample(now, { intensityScale: 1.86 });
  if (pulse && now - pulse.startedAt > pulse.durationMs) pulse = null;
  const parameters = sampleCubismBehaviorFrame(performanceFrame, now, { momentaryPulse: pulse });
  // Keep the App's explicit rig controls, with the same envelope as before.
  for (const target of manual) {
    const elapsed = now - manualAt - Number(target.delayMs || 0);
    const duration = Number(target.durationMs) || 900;
    if (elapsed < 0 || elapsed > duration) continue;
    const phase = elapsed / duration;
    const smooth = x => { const t = Math.max(0, Math.min(1, x)); return t < .5 ? 4*t*t*t : 1 - Math.pow(-2*t+2, 3)/2; };
    const envelope = phase < .28 ? smooth(phase/.28) : phase > .76 ? smooth((1-phase)/.24) : 1;
    const index = parameters.findIndex(p => p.id === target.id);
    const amount = Math.max(0, Math.min(1, Number(target.weight ?? 1))) * envelope;
    if (amount <= 0) continue;
    const base = index >= 0 ? parameters[index] : null;
    // Compose weighted sets, retaining Studio's pose at both envelope edges.
    const weight = amount + (base?.weight || 0) * (1 - amount);
    const value = (target.value * amount + (base ? base.value * base.weight * (1 - amount) : 0)) / weight;
    if (index >= 0) parameters.splice(index, 1);
    parameters.push({id: target.id, value, weight});
  }
  const plan = performanceFrame.behaviorPlan;
  return { parameters, expression: performanceFrame.expression || 'neutral',
    active: performanceFrame.active, planActive: Boolean(plan), mode: performanceFrame.character.mode,
    elapsedMs: performanceFrame.elapsedMs, durationMs: plan?.durationMs || 0 };
}
globalThis.__studioInvoke = command => {
  if (!command || typeof command !== 'object') throw new Error('Invalid motion command');
  if (Number.isFinite(command.now)) now = Math.max(now, command.now);
  if (command.kind === 'reset') { reset(command.seed); return {ready: true}; }
  if (!brain) reset(1);
  if (command.kind === 'state') { brain.onExternalState(command.value, now); return {}; }
  if (command.kind === 'act') {
    const value = command.value || {};
    const compiled = compileBehaviorIntent(value);
    const before = brain.getBehaviorPlan();
    const result = brain.onRoomAct({...value, ...compiled, source: value.source || 'room-act'}, now);
    const accepted = !before || result.behaviorPlan !== before || !compiled?.behaviorActions?.length;
    if (accepted) {
      manual = Array.isArray(value.parameters) ? value.parameters.slice(0, 32) : [];
      manualAt = now;
      if (result.expression === 'tongue') pulse = {startedAt: now + 80, durationMs: 620};
    }
    return {accepted};
  }
  if (command.kind === 'frame') return frame(Math.max(0, Math.min(1, Number(command.mouth) || 0)));
  throw new Error('Unknown motion command');
};
