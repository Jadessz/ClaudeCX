// "Your ClaudeCX data": everything ClaudeCX created on this computer, with a guarded wipe.
import { useCallback, useEffect, useRef, useState } from 'react';
import { Check, CircleAlert, CircleCheck, Eraser, OctagonX, TriangleAlert } from 'lucide-react';
import { API_DATA, API_WIPE, api } from './api.js';
import { formatBytes } from './format.js';

export function DataCard({ onRemoved, onChanged, disabled }) {
  const [state, setState] = useState({ status: 'loading', data: null });
  const [chosen, setChosen] = useState([]);
  const [typed, setTyped] = useState('');
  const [result, setResult] = useState({ kind: '', text: '' });
  const [busy, setBusy] = useState(false);
  const dialogRef = useRef(null);
  const openerRef = useRef(null);

  const load = useCallback(async () => {
    try {
      const response = await api(API_DATA);
      if (!response.ok || !response.body) { setState({ status: 'error', data: null }); return; }
      setState({ status: 'ok', data: response.body });
      setChosen((current) => current.length
        ? current.filter((id) => response.body.items.some((item) => item.id === id && item.exists))
        : response.body.items.filter((item) => item.default && item.exists).map((item) => item.id));
    } catch {
      setState({ status: 'error', data: null });
    }
  }, []);
  useEffect(() => { if (!disabled) { load(); } }, [load, disabled]);

  if (state.status === 'loading') { return null; }
  if (!state.data) {
    return <p className="field-error">Your ClaudeCX data could not be listed. Use Check again to retry.</p>;
  }
  const items = state.data.items;
  const selected = items.filter((item) => chosen.includes(item.id));
  const selectedBytes = selected.reduce((sum, item) => sum + item.bytes, 0);
  const totalBytes = items.filter((item) => item.id !== 'app').reduce((sum, item) => sum + item.bytes, 0);
  const confirmWord = state.data.confirmation;
  const toggle = (id) => setChosen((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id]);

  const openDialog = () => {
    setTyped('');
    setResult({ kind: '', text: '' });
    const dialog = dialogRef.current;
    if (dialog && !dialog.open) { dialog.showModal(); }
  };
  const closeDialog = () => {
    const dialog = dialogRef.current;
    if (dialog && dialog.open) { dialog.close(); }
    openerRef.current?.focus();
  };
  const wipe = async () => {
    setBusy(true);
    try {
      const response = await api(API_WIPE, 'POST', { items: chosen, confirm: typed });
      closeDialog();
      if (response.ok && response.body) {
        const problems = response.body.results.flatMap((item) => item.errors);
        const freed = response.body.results.reduce((sum, item) => sum + item.freed_bytes, 0);
        if (response.body.uninstalling) { onRemoved(); return; }
        setResult(problems.length
          ? { kind: 'invalid', text: 'Some files could not be deleted (they may be open in another program): ' + problems.join(' ') }
          : { kind: 'saved', text: 'Deleted ' + response.body.results.map((item) => item.label.toLowerCase()).join(', ') + ' and freed ' + formatBytes(freed) + '.' });
        setChosen([]);
        load();
        onChanged();
      } else {
        setResult({ kind: 'invalid', text: response.body && response.body.messages ? response.body.messages.join(' ') : 'Nothing was deleted (HTTP ' + response.status + ').' });
      }
    } catch {
      closeDialog();
      setResult({ kind: 'invalid', text: 'The control center is unreachable. Nothing was confirmed as deleted.' });
    }
    setBusy(false);
  };

  return (
    <section className="card danger-card" aria-labelledby="data-title">
      <header className="card-head">
        <span className="card-icon danger" aria-hidden="true"><Eraser size={16} /></span>
        <div>
          <h2 id="data-title" className="card-title">Your ClaudeCX data</h2>
          <p className="card-text">Everything ClaudeCX created on this computer: {formatBytes(totalBytes)} of logs, settings, and backups, plus the app itself. Choose what to delete. Nothing in your projects is touched.</p>
        </div>
      </header>
      {state.data.run_active && (
        <div className="card-body">
          <div className="banner" data-tone="warning" role="status">
            <CircleAlert aria-hidden="true" size={18} />
            <p>A run is in progress. Deleting is available again once it finishes.</p>
          </div>
        </div>
      )}
      <ul className="data-list">
        {items.map((item) => (
          <li key={item.id} data-empty={!item.exists || undefined} data-danger={item.id === 'app' || undefined}>
            <label className="data-row">
              <input
                type="checkbox"
                className="check"
                checked={chosen.includes(item.id)}
                disabled={!item.exists || disabled}
                onChange={() => toggle(item.id)}
              />
              <span className="check-box" aria-hidden="true"><Check size={13} /></span>
              <span className="data-text">
                <span className="data-label">{item.label}</span>
                <span className="data-description">{item.description}</span>
                {item.exists && item.warning && <span className="data-warning"><TriangleAlert aria-hidden="true" size={13} /> {item.warning}</span>}
              </span>
              <span className="data-size mono">{item.exists ? (item.id === 'app' ? 'installed' : formatBytes(item.bytes)) : 'nothing here'}</span>
            </label>
            {item.exists && (
              <details className="data-paths">
                <summary>{item.paths.length === 1 ? '1 location' : item.paths.length + ' locations'}</summary>
                <ul>{item.paths.map((path) => <li key={path} className="mono">{path}</li>)}</ul>
              </details>
            )}
          </li>
        ))}
      </ul>
      <div className="card-body data-actions">
        <span className="muted">{selected.length ? selected.length + ' selected · ' + formatBytes(selectedBytes) : 'Nothing selected'}</span>
        <button type="button" ref={openerRef} className="button danger" onClick={openDialog} disabled={selected.length === 0 || state.data.run_active || disabled}>
          <Eraser aria-hidden="true" size={14} /> Delete selected…
        </button>
      </div>
      {result.text && (
        <div className="card-body">
          <div className="banner" data-tone={result.kind === 'saved' ? 'success' : 'danger'} role="status">
            {result.kind === 'saved' ? <CircleCheck aria-hidden="true" size={18} /> : <CircleAlert aria-hidden="true" size={18} />}
            <p>{result.text}</p>
          </div>
        </div>
      )}

      <dialog ref={dialogRef} className="stop-dialog wipe-dialog" aria-labelledby="wipe-title" aria-describedby="wipe-text" onCancel={closeDialog}>
        <h2 id="wipe-title"><OctagonX aria-hidden="true" size={18} /> Delete permanently?</h2>
        <p id="wipe-text">These are deleted for good. They do not go to the Recycle Bin, and nothing can bring them back.</p>
        <ul className="wipe-list">
          {selected.map((item) => (
            <li key={item.id}>
              <span className="data-label">{item.label}{item.id !== 'app' && <span className="muted"> · {formatBytes(item.bytes)}</span>}</span>
              {item.warning && <span className="data-warning"><TriangleAlert aria-hidden="true" size={13} /> {item.warning}</span>}
            </li>
          ))}
        </ul>
        {chosen.includes('app') && <p className="wipe-note">The control center closes after removing itself. Your projects and your Claude and Codex accounts are not affected.</p>}
        <label htmlFor="wipe-confirm" className="setting-label">Type <code>{confirmWord}</code> to confirm</label>
        <input id="wipe-confirm" className="input mono wipe-input" value={typed} autoComplete="off" spellCheck={false} onChange={(event) => setTyped(event.target.value)} />
        <div className="dialog-actions">
          <button type="button" className="button" onClick={closeDialog} autoFocus>Cancel</button>
          <button type="button" className="button danger solid" onClick={wipe} disabled={typed !== confirmWord || busy}>
            {busy ? 'Deleting…' : 'Delete permanently'}
          </button>
        </div>
      </dialog>
    </section>
  );
}
