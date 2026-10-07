// A tiny DOM builder. Text always goes in as text nodes (never innerHTML), so
// names and notes from an opened pack can't inject markup.

type Child = Node | string | number | null | undefined | false;
type Attrs = Record<string, unknown>;

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Attrs = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue;
    if (key.startsWith('on') && typeof value === 'function') {
      el.addEventListener(key.slice(2).toLowerCase(), value as EventListener);
    } else if (key === 'class') {
      el.className = String(value);
    } else if (key === 'style' && typeof value === 'object') {
      Object.assign(el.style, value);
    } else if (key in el && typeof value !== 'string') {
      (el as unknown as Record<string, unknown>)[key] = value;
    } else if (key === 'value' || key === 'checked') {
      (el as unknown as Record<string, unknown>)[key] = value;
    } else {
      el.setAttribute(key, value === true ? '' : String(value));
    }
  }
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : String(child));
  }
  return el;
}

/** A labelled text input bound to get/set. */
export function field(
  label: string,
  value: string,
  onChange: (v: string) => void,
  opts: { placeholder?: string; multiline?: boolean; hint?: string } = {},
): HTMLElement {
  const input = opts.multiline
    ? h('textarea', { rows: 4, placeholder: opts.placeholder ?? '', value })
    : h('input', { type: 'text', placeholder: opts.placeholder ?? '', value });
  input.addEventListener('input', () => onChange((input as HTMLInputElement).value));
  return h('label', { class: 'field' }, h('span', {}, label), input, opts.hint ? h('small', {}, opts.hint) : null);
}

export function select(
  label: string,
  value: string,
  options: [string, string][],
  onChange: (v: string) => void,
): HTMLElement {
  const sel = h('select', {}, ...options.map(([v, text]) => h('option', { value: v, selected: v === value }, text)));
  sel.addEventListener('change', () => onChange(sel.value));
  return h('label', { class: 'field' }, h('span', {}, label), sel);
}

export function icon(name: string, color?: string): HTMLElement {
  return h('span', { class: 'material-icons', style: color ? { color } : {} }, name);
}
