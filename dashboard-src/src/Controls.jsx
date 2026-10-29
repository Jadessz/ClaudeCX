// Form controls for the control center: a themed select with a listbox, a number stepper, a switch,
// a path tag editor, and a search field. All text is rendered as React text nodes.
import { useEffect, useId, useRef, useState } from 'react';
import { Check, ChevronDown, Minus, Plus, Search, X } from 'lucide-react';

// A button that opens a listbox. Keyboard: arrows, Home/End, Enter/Space to choose, Escape to close.
export function Select({ id, value, options, onChange, describedBy, label }) {
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const rootRef = useRef(null);
  const buttonRef = useRef(null);
  const listRef = useRef(null);
  const listId = useId();
  const selectedIndex = Math.max(0, options.findIndex((option) => option.value === value));
  const selected = options[selectedIndex];

  useEffect(() => {
    if (!open) { return undefined; }
    const onDown = (event) => { if (rootRef.current && !rootRef.current.contains(event.target)) { setOpen(false); } };
    document.addEventListener('mousedown', onDown);
    listRef.current?.focus();
    return () => document.removeEventListener('mousedown', onDown);
  }, [open]);

  const openList = () => { setActive(selectedIndex); setOpen(true); };
  const choose = (index) => {
    setOpen(false);
    onChange(options[index].value);
    buttonRef.current?.focus();
  };
  const onButtonKey = (event) => {
    if (['ArrowDown', 'ArrowUp', 'Enter', ' '].includes(event.key)) { event.preventDefault(); openList(); }
  };
  const onListKey = (event) => {
    if (event.key === 'ArrowDown') { event.preventDefault(); setActive((index) => Math.min(options.length - 1, index + 1)); }
    else if (event.key === 'ArrowUp') { event.preventDefault(); setActive((index) => Math.max(0, index - 1)); }
    else if (event.key === 'Home') { event.preventDefault(); setActive(0); }
    else if (event.key === 'End') { event.preventDefault(); setActive(options.length - 1); }
    else if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); choose(active); }
    else if (event.key === 'Escape') { event.preventDefault(); setOpen(false); buttonRef.current?.focus(); }
    else if (event.key === 'Tab') { setOpen(false); }
  };

  return (
    <div className="select" ref={rootRef} data-open={open || undefined}>
      <button
        id={id}
        ref={buttonRef}
        type="button"
        className="select-button"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={listId}
        aria-describedby={describedBy}
        aria-label={label ? label + ': ' + (selected ? selected.label : '') : undefined}
        onClick={() => (open ? setOpen(false) : openList())}
        onKeyDown={onButtonKey}
      >
        <span className="select-value">
          <span className="select-label">{selected ? selected.label : '—'}</span>
          {selected && selected.description && <span className="select-description">{selected.description}</span>}
        </span>
        <ChevronDown aria-hidden="true" size={16} className="select-chevron" />
      </button>
      {open && (
        <ul
          id={listId}
          ref={listRef}
          className="select-list"
          role="listbox"
          tabIndex={-1}
          aria-activedescendant={listId + '-' + active}
          onKeyDown={onListKey}
        >
          {options.map((option, index) => (
            <li
              key={option.value}
              id={listId + '-' + index}
              role="option"
              aria-selected={option.value === value}
              data-active={index === active || undefined}
              onMouseEnter={() => setActive(index)}
              onClick={() => choose(index)}
            >
              <span className="option-text">
                <span className="option-label">{option.label}</span>
                {option.description && <span className="option-description">{option.description}</span>}
              </span>
              {option.value === value && <Check aria-hidden="true" size={16} className="option-check" />}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// A number field with minus and plus buttons, the unit inside the field, and the allowed range.
export function NumberField({ id, value, min, max, step = 1, unit, onChange, describedBy, decimals = 0 }) {
  const numeric = Number(value);
  const valid = value !== '' && Number.isFinite(numeric);
  const nudge = (direction) => {
    const base = valid ? numeric : min;
    const next = Math.min(max, Math.max(min, base + direction * step));
    onChange(String(Number(next.toFixed(decimals))));
  };
  const outOfRange = valid && (numeric < min || numeric > max);
  return (
    <div className="stepper" data-invalid={!valid || outOfRange || undefined}>
      <button type="button" className="stepper-button" onClick={() => nudge(-1)} disabled={valid && numeric <= min} aria-label="Decrease" tabIndex={-1}>
        <Minus aria-hidden="true" size={14} />
      </button>
      <span className="stepper-field">
        <input
          id={id}
          type="number"
          inputMode={decimals ? 'decimal' : 'numeric'}
          min={min}
          max={max}
          step={decimals ? 0.01 : 1}
          value={value}
          aria-describedby={describedBy}
          aria-invalid={!valid || outOfRange}
          onChange={(event) => onChange(event.target.value)}
        />
        {unit && <span className="stepper-unit">{unit}</span>}
      </span>
      <button type="button" className="stepper-button" onClick={() => nudge(1)} disabled={valid && numeric >= max} aria-label="Increase" tabIndex={-1}>
        <Plus aria-hidden="true" size={14} />
      </button>
    </div>
  );
}

export function Switch({ id, checked, onChange, describedBy, labelledBy }) {
  return (
    <button
      id={id}
      type="button"
      role="switch"
      className="switch"
      aria-checked={checked}
      aria-describedby={describedBy}
      aria-labelledby={labelledBy}
      onClick={() => onChange(!checked)}
    >
      <span className="switch-thumb" aria-hidden="true" />
      <span className="switch-text" aria-hidden="true">{checked ? 'On' : 'Off'}</span>
    </button>
  );
}

// Protected paths as removable chips, with an input that adds on Enter or comma.
export function TagInput({ id, values, onChange, suggestions = [], describedBy, placeholder }) {
  const [text, setText] = useState('');
  const [error, setError] = useState('');
  const add = (raw) => {
    const value = raw.trim().replaceAll('\\', '/');
    if (!value) { return; }
    if (value.split('/').includes('..') || value.includes(':')) { setError('Use a path inside the project, without ".." or a drive letter.'); return; }
    if (!values.includes(value)) { onChange([...values, value]); }
    setText('');
    setError('');
  };
  const onKey = (event) => {
    if (event.key === 'Enter' || event.key === ',') { event.preventDefault(); add(text); }
    else if (event.key === 'Backspace' && text === '' && values.length > 0) { onChange(values.slice(0, -1)); }
  };
  const unused = suggestions.filter((item) => !values.includes(item));
  return (
    <div className="tags">
      <div className="tags-box" data-invalid={error ? true : undefined}>
        <ul className="tags-list" aria-label="Protected paths">
          {values.map((value) => (
            <li key={value} className="tag-chip">
              <span className="mono">{value}</span>
              <button type="button" className="tag-remove" onClick={() => onChange(values.filter((item) => item !== value))} aria-label={'Remove ' + value}>
                <X aria-hidden="true" size={13} />
              </button>
            </li>
          ))}
        </ul>
        <input
          id={id}
          className="tags-input mono"
          value={text}
          placeholder={values.length ? 'Add another path' : placeholder}
          spellCheck={false}
          aria-describedby={describedBy}
          onChange={(event) => { setText(event.target.value); setError(''); }}
          onKeyDown={onKey}
          onBlur={() => add(text)}
        />
      </div>
      {error && <p className="field-error" role="alert">{error}</p>}
      {unused.length > 0 && (
        <div className="tag-suggestions">
          <span className="muted">Common:</span>
          {unused.map((item) => (
            <button key={item} type="button" className="suggestion" onClick={() => add(item)}>
              <Plus aria-hidden="true" size={12} /> <span className="mono">{item}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export function SearchField({ id, value, onChange, placeholder, label }) {
  return (
    <span className="search">
      <Search aria-hidden="true" size={15} className="search-icon" />
      <label className="visually-hidden" htmlFor={id}>{label}</label>
      <input id={id} type="search" value={value} placeholder={placeholder} onChange={(event) => onChange(event.target.value)} />
      {value && (
        <button type="button" className="search-clear" onClick={() => onChange('')} aria-label="Clear the filter">
          <X aria-hidden="true" size={13} />
        </button>
      )}
    </span>
  );
}
