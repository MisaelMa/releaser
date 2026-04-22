# Conventional Commits

Releaser puede leer tu historial de git y decidir automáticamente qué apps
bumpear y con qué tipo (major/minor/patch).

> **Feature opt-in**. Esta integración con [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
> está **desactivada por default**. Si no activas `commits: [enabled: true]`
> en tu `mix.exs`, todo lo descrito aquí se ignora y Releaser funciona como
> una herramienta de releases manual (ver [Manual releases](./manual-releases.md)).
>
> Ambos caminos son soportados de primera clase.

## Activar la feature

En tu `mix.exs`:

```elixir
releaser: [
  apps_root: ".",
  commits: [enabled: true]
]
```

Con eso basta — los defaults sensatos se aplican. Si quieres personalizar:

```elixir
releaser: [
  commits: [
    enabled: true,
    bump_rules: %{
      "feat" => :minor,
      "fix" => :patch,
      "perf" => :patch,
      "refactor" => :patch,
      "revert" => :patch
    },
    breaking_bump: :major,
    breaking_markers: [:bang, :body],
    scope_aliases: %{"autenticacion" => "auth"},
    no_scope: :warn
  ]
]
```

## La tabla: tipo de commit → bump

| Tipo | Ejemplo | Bump |
|------|---------|------|
| `feat` | `feat(xml): add carta_porte 3.1` | **minor** |
| `fix` | `fix(csd): handle empty key` | **patch** |
| `perf` | `perf(xml): faster parsing` | **patch** |
| `refactor` | `refactor(csd): extract Signer` | **patch** |
| `revert` | `revert(xml): revert X` | **patch** |
| `docs` | `docs(xml): update README` | *(ninguno)* |
| `chore` | `chore: bump deps` | *(ninguno)* |
| `test` | `test(xml): add cases` | *(ninguno)* |
| `style` / `build` / `ci` | `ci: add coverage` | *(ninguno)* |

## BREAKING CHANGE

Dos formas de marcar un breaking change (ambas se activan por default):

### 1. El `!` inline

```
feat(xml)!: rename CFDI.sign to CFDI.sign_with_csd
fix(csd)!: remove deprecated load_key/1
```

Va después del tipo o el scope, antes de los dos puntos.

### 2. `BREAKING CHANGE:` en el body

```
feat(xml): add new signer

BREAKING CHANGE: CFDI.sign/2 was renamed to CFDI.sign_with_csd/2.
```

También acepta `BREAKING-CHANGE:` (con guion).

**Cualquier commit con alguno de estos markers se bumpea a `major`** —
incluso tipos que normalmente no bumpean (`docs`, `chore`).

## Agregación: muchos commits → un solo bump

Si tienes 10 commits desde el último tag, **no son 10 bumps**. Es UN bump
del tipo más agresivo presente.

```
feat(xml): X1
feat(xml): X2
fix(xml): Y
refactor(xml): Z
```

→ `minor` (un solo bump). Si entre esos hay `feat(xml)!:` → `major`.

Jerarquía: `major > minor > patch > ninguno`.

## Scopes y apps

El **scope del commit** determina a qué app se aplica:

```
feat(xml): ...    → app llamado "xml" (o "cfdi_xml" con prefix-stripping)
fix(csd): ...     → app "csd" o "cfdi_csd" o "sat_csd"
```

### Scope aliases

Si el scope no coincide con el nombre del app, configura:

```elixir
commits: [
  enabled: true,
  scope_aliases: %{
    "autenticacion" => "sat_auth",
    "certificados" => "cfdi_csd"
  }
]
```

### Prefix stripping automático

Si tu app se llama `cfdi_xml` y el commit es `feat(xml): ...`, Releaser
reconoce la relación automáticamente quitando prefijos comunes (`cfdi_`,
`sat_`, `clir_`, `renapo_`).

### Commits sin scope

Por defecto (`no_scope: :warn`), se ignoran con un warning. Opciones:

- `:ignore` — silencioso
- `:warn` — warning en stdout (default)

## Comandos

### Sugerir (análisis sin aplicar)

```bash
mix releaser.bump --suggest
```

Output:

```
Analyzing commits since v4.0.18...

Apps to bump:
  xml       4.0.18 → 4.1.0     (minor — 3 commit(s))
  csd       4.0.16 → 4.0.17    (patch — 1 commit(s))
  auth      1.0.1  → 2.0.0     (major — 1 commit(s))

Apps with no relevant changes:
  renapo

Run with --from-commits to apply.
```

### Aplicar

```bash
# Todos los apps que tengan commits relevantes
mix releaser.bump --from-commits

# Solo un app
mix releaser.bump xml --from-commits

# En canal pre-release
mix releaser.bump --from-commits --mode prerelease --tag dev

# Desde un tag específico (no el último)
mix releaser.bump --from-commits --since v4.0.0
```

### No-op (sin commits relevantes)

Si no hay commits que disparen bump, el comando termina exitosamente sin
modificar nada:

```
$ mix releaser.bump --from-commits

No relevant commits since v4.0.18. No bump.
```

Esto es importante para CI: si nadie hizo un `feat`/`fix` desde el último
release, el workflow no bumpea ni publica. Idempotente.

## Gitflow: dev / beta / main

Con Conventional Commits activo + el workflow de GitHub Actions incluido,
el flujo es:

1. **Dev trabaja en una feature branch**:

   ```bash
   git checkout -b feature/carta-porte-31
   # ... código ...
   git commit -m "feat(xml): add carta_porte 3.1 support"
   git push -u origin feature/carta-porte-31
   # abre PR a dev
   ```

2. **Merge a `dev`** → GitHub Actions detecta el push, lee el commit
   `feat(xml)`, y automáticamente:
   - Bumpea `xml` a `4.1.0-dev.1`
   - Commitea `chore(release): auto-bump on dev`
   - Crea tag `v4.1.0-dev.1`
   - Pushea

3. **Merge dev → beta** → Actions bumpea a `4.1.0-beta.1`.

4. **Merge beta → main** → Actions bumpea a `4.1.0` estable y,
   si `PUBLISH_TO_HEX=true`, publica a Hex + crea GitHub Release.

## Pre-commit hooks

Para evitar que commits mal formateados entren al repo, Releaser incluye un
hook de git que valida cada mensaje.

### Instalación

```bash
mix releaser.install_hooks
```

Eso ejecuta `git config core.hooksPath .githooks` — todos los hooks del
repo se activan en una sola línea. Cada dev del proyecto tiene que correrlo
una vez después de clonar.

### Qué valida

Sigue estrictamente [Conventional Commits v1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):

- Formato: `<type>(<scope>)?(!)?: <subject>`
- `BREAKING CHANGE:` / `BREAKING-CHANGE:` **en mayúsculas** (la spec lo exige)
- Línea en blanco obligatoria entre header y body cuando hay body
- Subject no puede estar vacío
- Subject no puede exceder `max_subject_length` (default 100)

### Configuración

En tu `mix.exs`:

```elixir
releaser: [
  commits: [
    enabled: true,
    validation: [
      # Si true, solo tipos declarados en bump_rules + allowed_types son válidos.
      strict_types: false,

      # Tipos adicionales válidos (que NO bumpean pero son aceptados).
      allowed_types: ~w[docs chore test style build ci],

      # Si true, solo scopes declarados son válidos.
      strict_scopes: false,

      # Lista explícita de scopes. Si omites, se auto-infiere de app names
      # + scope_aliases.
      allowed_scopes: nil,

      # Permitir commits sin scope (`feat: ...` sin paréntesis).
      allow_no_scope: true,

      # Longitud máxima del subject.
      max_subject_length: 100
    ]
  ]
]
```

### Modos

| Modo | `strict_types` | `strict_scopes` | Para qué |
|---|---|---|---|
| **Permisivo** (default) | `false` | `false` | Solo valida formato. Bueno para empezar. |
| **Strict** | `true` | `true` | Solo tipos/scopes declarados. Para proyectos maduros. |

### Ejemplos de errores

```
$ git commit -m "fix stuff"
✗ Commit message invalid

    fix stuff

Commit message does not match Conventional Commits format.
Expected: <type>(<scope>)?(!)?: <subject>
```

```
$ git commit -m "feat(xmll): ..."   # en modo strict
✗ Commit message invalid

    feat(xmll): ...

Unknown scope "xmll".
Allowed scopes: releaser, rel, release
```

### Bypass (no recomendado)

```bash
git commit --no-verify -m "emergency fix"
```

### Desinstalar

```bash
git config --unset core.hooksPath
```

## Variables del workflow

Configura en Settings → Actions → Variables:

| Nombre | Valores | Qué hace |
|--------|---------|----------|
| `PUBLISH_TO_HEX` | `true` / `false` | Publica a Hex en push a `main`. Default `false`. |
| `CREATE_GH_RELEASE` | `true` / `false` | Crea GitHub Release en push a `main`. Default `false`. |

Secret requerido si `PUBLISH_TO_HEX=true`:

- `HEX_API_KEY` — Obtén una con `mix hex.user whoami` / `mix hex.user key generate`.
