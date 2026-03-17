declare module 'prismjs' {
  namespace Prism {
    export type Grammar = unknown;

    export interface PrismStatic {
      languages: Record<string, Grammar | undefined>;
      highlight(code: string, grammar: Grammar, language: string): string;
    }
  }

  const Prism: Prism.PrismStatic;
  export default Prism;
}

declare module 'prismjs/components/*';
