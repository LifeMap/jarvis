export interface SqlExecutor {
  sql<T = Record<string, string | number | boolean | null>>(
    strings: TemplateStringsArray,
    ...values: (string | number | boolean | null)[]
  ): T[];
}
