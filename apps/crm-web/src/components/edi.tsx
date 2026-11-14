import { useId } from "react";

/**
 * Edi, the Edge-Care guide, in its "listening" pose. A direct port of `EdiView.draw`
 * in packages/edgecare-core/Sources/EdgeCareUI/Theme.swift so the CRM shows the same
 * character as the kiosk, patient and doctor apps. Decorative: hidden from assistive tech.
 */
export function Edi({ className = "edi" }: { className?: string }) {
  const gradient = `edi-body-${useId().replace(/:/g, "")}`;
  const arch = "M22 103V45C22 29.5 34.5 17 50 17S78 29.5 78 45V103";
  const arm = (x: number, angle: number) => <rect x={-7} y={-3} width={14} height={30} rx={7}
    transform={`translate(${x} 54) rotate(${angle})`} fill="#830051" stroke="#d0006f" strokeOpacity={0.55} strokeWidth={1.2} />;
  return <svg className={className} viewBox="0 0 146 132" aria-hidden="true" focusable="false">
    <defs><linearGradient id={gradient} gradientUnits="userSpaceOnUse" x1={0} y1={0} x2={100} y2={120}>
      <stop offset="0" stopColor="#a3086a" /><stop offset=".5" stopColor="#830051" /><stop offset="1" stopColor="#67003f" />
    </linearGradient></defs>
    <g transform="translate(15 4)">
      <ellipse cx={50} cy={121.5} rx={46} ry={4.5} fill="#830051" fillOpacity={0.1} />
      <path d={arch} transform="translate(-1.4 -1.2)" fill="none" stroke="#d0006f" strokeWidth={34} strokeLinecap="round" strokeLinejoin="round" />
      <path d={arch} transform="translate(.6 .5)" fill="none" stroke={`url(#${gradient})`} strokeWidth={34} strokeLinecap="round" strokeLinejoin="round" />
      {arm(4, 12.6)}{arm(96, -12.6)}
      <path d="M30 31C30 18 39 9 50 9S70 18 70 31Q50 34 30 31Z" fill="#f7f2eb" />
      <ellipse cx={43} cy={19.5} rx={1.7} ry={2.3} fill="#3a1f24" />
      <ellipse cx={57} cy={19.5} rx={1.7} ry={2.3} fill="#3a1f24" />
      <path d="M45.6 25Q50 29 54.4 25" fill="none" stroke="#3a1f24" strokeWidth={1.5} strokeLinecap="round" />
    </g>
  </svg>;
}
