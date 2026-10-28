// The collaboration stepper. Codex review is never shown as complete: it happens after this dashboard.
import { CircleCheck, CircleDashed, CircleDot, CircleX, Loader, OctagonX } from 'lucide-react';

export function StatusIcon({ status, size = 16 }) {
  const props = { 'aria-hidden': true, size };
  if (status === 'succeeded' || status === 'done') { return <CircleCheck {...props} />; }
  if (status === 'failed') { return <CircleX {...props} />; }
  if (status === 'stopped') { return <OctagonX {...props} />; }
  if (status === 'active' || status === 'loading') { return <Loader className="spin" {...props} />; }
  if (status === 'next') { return <CircleDot {...props} />; }
  return <CircleDashed {...props} />;
}

function implementationStep(status) {
  switch (status) {
    case 'active': return ['active', 'Running now'];
    case 'succeeded': return ['succeeded', 'Finished with a report'];
    case 'stopped': return ['stopped', 'Stopped from this dashboard'];
    case 'failed': return ['failed', 'Ended without a report'];
    default: return ['pending', 'Waiting for the bridge'];
  }
}

export function CollaborationFlow({ status, originalAvailable, briefAvailable }) {
  const [implState, implDetail] = implementationStep(status);
  const finished = status === 'succeeded' || status === 'stopped' || status === 'failed';
  const steps = [
    {
      id: 'request',
      title: 'Your request',
      state: originalAvailable === false ? 'muted' : originalAvailable ? 'done' : 'pending',
      detail: originalAvailable === false ? 'Not captured for this run' : originalAvailable ? 'Captured as sent to Codex' : 'Loading'
    },
    {
      id: 'handoff',
      title: 'Codex handoff',
      state: briefAvailable ? 'done' : briefAvailable === false ? 'failed' : 'pending',
      detail: briefAvailable ? 'Brief delivered to Claude' : briefAvailable === false ? 'Brief copy unavailable' : 'Loading'
    },
    { id: 'implementation', title: 'Claude implementation', state: implState, detail: implDetail },
    {
      id: 'review',
      title: 'Codex review',
      state: finished ? 'next' : 'pending',
      detail: finished ? 'Next: Codex inspects the result' : 'After Claude finishes'
    }
  ];
  return (
    <nav className="flow" aria-label="Collaboration flow">
      <ol>
        {steps.map((step, index) => (
          <li key={step.id} className="flow-step" data-state={step.state} aria-current={step.state === 'active' ? 'step' : undefined}>
            <span className="flow-index" aria-hidden="true">{index + 1}</span>
            <span className="flow-icon"><StatusIcon status={step.state} size={16} /></span>
            <span className="flow-text">
              <span className="flow-title">{step.title}</span>
              <span className="flow-detail">{step.detail}</span>
            </span>
          </li>
        ))}
      </ol>
    </nav>
  );
}
