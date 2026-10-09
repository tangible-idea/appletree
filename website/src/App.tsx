import { useEffect, useState, type ReactNode } from "react";
import { copy, type Lang } from "./i18n";

const DOWNLOAD_URL: string = import.meta.env.VITE_DOWNLOAD_URL || "downloads/AppleTree.dmg";
const LANG_KEY = "appletree-site-lang";

type Release = { version: string; bytes: number };

/** English is the default; a `?lang=ko` link or a saved choice switches it. */
function initialLang(): Lang {
  const param = new URLSearchParams(window.location.search).get("lang");
  if (param === "en" || param === "ko") return param;
  try {
    const saved = localStorage.getItem(LANG_KEY);
    if (saved === "en" || saved === "ko") return saved;
  } catch {
    // Storage can be unavailable (private windows); fall back to English.
  }
  return "en";
}

function formatSize(bytes: number): string {
  return bytes >= 1_000_000 ? `${(bytes / 1_000_000).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1000))} KB`;
}

export default function App() {
  const [lang, setLang] = useState<Lang>(initialLang);
  const [release, setRelease] = useState<Release | null>(null);
  const t = copy[lang];

  useEffect(() => {
    document.documentElement.lang = t.htmlLang;
    try {
      localStorage.setItem(LANG_KEY, lang);
    } catch {
      // Ignore; the choice just won't be remembered.
    }
  }, [lang, t.htmlLang]);

  useEffect(() => {
    // Written by `npm run package-app`; missing when the dmg is hosted elsewhere.
    fetch("downloads/release.json")
      .then((response) => (response.ok ? response.json() : null))
      .then((data) => setRelease(data && typeof data.bytes === "number" ? data : null))
      .catch(() => setRelease(null));
  }, []);

  const meta = [
    ...(release ? [`v${release.version}`, `${formatSize(release.bytes)} · dmg`] : []),
    ...t.download.requirements,
  ];

  return (
    <div className="wrap">
      <header className="bar">
        <a className="brand" href="#top">
          <img src="icon.png" alt="" width={34} height={34} />
          appletree
        </a>
        <div className="bar-right">
          <nav aria-label="Sections">
            <a href="#features">{t.nav.features}</a>
            <a href="#cleanup">{t.nav.cleanup}</a>
            <a href="#install">{t.nav.install}</a>
          </nav>
          <button className="lang" type="button" onClick={() => setLang(lang === "en" ? "ko" : "en")}>
            {t.switchTo}
          </button>
        </div>
      </header>

      <main id="top">
        <div className="hero">
          <p className="eyebrow">{t.hero.eyebrow}</p>
          <h1>
            {t.hero.titleA}
            <br />
            <em>{t.hero.titleB}</em>
          </h1>
          <p className="lede">{t.hero.lede}</p>
          <div className="cta">
            <DownloadButton label={t.download.label} />
            <div className="meta">
              {meta.map((item) => (
                <span key={item}>{item}</span>
              ))}
            </div>
          </div>
          <figure className="shot">
            <img src={`screenshots/app-${lang}.png`} alt={t.hero.shotAlt} width={1320} height={920} />
          </figure>
        </div>

        <section id="features">
          <SectionHead eyebrow={t.features.eyebrow} title={t.features.title} intro={t.features.intro} />
          <div className="features">
            {t.features.items.map((item, index) => (
              <div className="feature" key={item.title}>
                <div className="ico">{featureIcons[index]}</div>
                <h3>{item.title}</h3>
                <p>{item.body}</p>
              </div>
            ))}
          </div>
        </section>

        <section id="cleanup">
          <div className="split">
            <div>
              <SectionHead eyebrow={t.cleanup.eyebrow} title={t.cleanup.title} intro={t.cleanup.intro} />
              <ul className="checks">
                {t.cleanup.checks.map((check) => (
                  <li key={check.title}>
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                      <path d="m5 12 5 5 9-10" />
                    </svg>
                    <p>
                      <strong>{check.title}</strong> <span>{check.body}</span>
                    </p>
                  </li>
                ))}
              </ul>
              <div className="scope">
                <table>
                  <thead>
                    <tr>
                      {t.cleanup.table.head.map((head) => (
                        <th scope="col" key={head}>{head}</th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {t.cleanup.table.rows.map(([what, where, rule], index) => (
                      <tr key={what}>
                        <td>
                          {what}
                          {index === 2 && <span className="optional"> {t.cleanup.table.optional}</span>}
                        </td>
                        <td className="path">{where}</td>
                        <td className="num">{rule}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
            <figure className="shot small">
              <img src={`screenshots/cleanup-${lang}.png`} alt={t.cleanup.shotAlt} width={680} height={680} />
            </figure>
          </div>
          <p className="note">{t.cleanup.note}</p>
        </section>

        <div className="band">
          {t.privacy.map((item) => (
            <div key={item.title}>
              <h3>{item.title}</h3>
              <p>{item.body}</p>
            </div>
          ))}
        </div>

        <section id="install">
          <SectionHead eyebrow={t.install.eyebrow} title={t.install.title} />
          <ol className="steps">
            {t.install.steps.map((step) => (
              <li key={step.title}>
                <p>
                  <strong>{step.title}</strong>
                  <span>{step.body}</span>
                </p>
              </li>
            ))}
          </ol>
          <p className="note">{t.install.note}</p>
        </section>

        <div className="final">
          <h2>{t.final}</h2>
          <DownloadButton label={t.download.label} />
        </div>
      </main>

      <footer>{t.footer} · <a href={lang === "ko" ? "privacy.html#ko" : "privacy.html"}>{t.privacyLink}</a></footer>
    </div>
  );
}

function SectionHead({ eyebrow, title, intro }: { eyebrow: string; title: string; intro?: string }) {
  return (
    <div className="section-head">
      <p className="eyebrow">{eyebrow}</p>
      <h2>{title}</h2>
      {intro && <p>{intro}</p>}
    </div>
  );
}

function DownloadButton({ label }: { label: string }) {
  return (
    <a className="btn" href={DOWNLOAD_URL} download="AppleTree.dmg">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M12 4v11" />
        <path d="m7 10 5 5 5-5" />
        <path d="M5 20h14" />
      </svg>
      {label}
    </a>
  );
}

function Icon({ children }: { children: ReactNode }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  );
}

// Same order as the feature list in i18n.ts.
const featureIcons = [
  <Icon key="map"><circle cx="12" cy="12" r="9" /><path d="M12 3v9l6.4 6.4" /></Icon>,
  <Icon key="list"><path d="M4 6h16M4 12h11M4 18h6" /></Icon>,
  <Icon key="search"><circle cx="11" cy="11" r="6" /><path d="m20 20-4.5-4.5" /></Icon>,
  <Icon key="zip"><path d="M4 7h16v13H4z" /><path d="M9 3h6v4H9z" /><path d="M12 11v5" /></Icon>,
  <Icon key="trash"><path d="M5 7h14" /><path d="M10 7V4h4v3" /><path d="M7 7l1 13h8l1-13" /></Icon>,
  <Icon key="pulse"><path d="M3 12h4l3-7 4 14 3-7h4" /></Icon>,
];
