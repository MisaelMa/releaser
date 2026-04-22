# Manual Releases

Releaser funciona perfectamente **sin Conventional Commits**. Esta guía es
para quienes prefieren decidir manualmente cada bump, sin automatización
basada en git log.

Si te interesa el flujo automático por commits, ver
[Conventional Commits](./conventional-commits.md).

## Diferencias en una tabla

|                              | Manual (esta guía)                        | Conventional Commits                      |
|------------------------------|-------------------------------------------|-------------------------------------------|
| Configuración en `mix.exs`   | Ninguna extra                             | `commits: [enabled: true]`                |
| Cómo decides el bump         | Tú, al correr el comando                  | El parser lo calcula desde `git log`      |
| Formato de commits           | Libre                                     | `<type>(<scope>)?: <subject>`             |
| Pre-commit hook              | No                                        | Opcional (`mix releaser.install_hooks`)   |
| GitHub Actions               | Opcional                                  | Opcional                                  |
| Cascade multi-app            | Sí                                        | Sí                                        |
| Pre-release tags             | Sí                                        | Sí                                        |
| Changelog automático         | Sí (con [Changelog hook](./changelog-and-hooks.md)) | Sí                         |

**Ambos flujos producen el mismo resultado final** (versión bumpeada,
commit, tag, opcionalmente publish). La única diferencia es **quién
decide el tipo de bump**.

## Flujo básico

### 1. Bumpear una versión

```bash
# Stable releases
mix releaser.bump releaser patch        # 1.0.0 → 1.0.1
mix releaser.bump releaser minor        # 1.0.1 → 1.1.0
mix releaser.bump releaser major        # 1.1.0 → 2.0.0

# En single-app puedes omitir el nombre
mix releaser.bump patch                 # 1.0.0 → 1.0.1
```

En single-app (`apps_root: "."`), el nombre del app se infiere — no hace
falta escribirlo. En monorepo (umbrella/poncho) es obligatorio.

### 2. Pre-releases

```bash
mix releaser.bump major --mode prerelease --tag dev
# 1.0.0 → 2.0.0-dev.1

mix releaser.bump --mode prerelease --tag dev
# 2.0.0-dev.1 → 2.0.0-dev.2

mix releaser.bump --mode prerelease --tag beta
# 2.0.0-dev.5 → 2.0.0-beta.1

mix releaser.bump release
# 2.0.0-beta.1 → 2.0.0
```

Ver [Pre-release tags](./pre-release-tags.md) para el detalle.

### 3. Commit y tag de git (tú mismo)

Releaser modifica `mix.exs` pero **no toca git**. Tú commiteas y tageas:

```bash
git add mix.exs CHANGELOG.md
git commit -m "Release v1.1.0"           # mensaje libre
git tag v1.1.0
git push && git push --tags
```

Si quieres que git-tag sea automático, Releaser trae un
[hook de git tag](./changelog-and-hooks.md#git-tag-hook).

### 4. Publicar a Hex

```bash
mix releaser.publish
# o, dry-run primero:
mix releaser.publish --dry-run
```

Ver [Publishing to Hex](./publishing-to-hex.md) para detalles (package
defaults, organización, topological order en monorepo).

## Flujo completo en un monorepo

Para umbrella/poncho con varios apps, bumpeas uno a la vez y Releaser
aplica cascade (bump patch a los apps que dependen del que bumpeaste):

```bash
# Bump manual del core
mix releaser.bump xml minor
#   xml      4.0.18 → 4.1.0    (direct)
#   cfdi     4.0.14 → 4.0.15   (cascade)
#   auth     1.0.1  → 1.0.2    (cascade)

# Publica en orden topológico
mix releaser.publish
```

## Gitflow: dev / beta / main sin commits convencionales

El workflow de ramas funciona idéntico — solo que tú decides el bump en
cada paso:

```bash
# En rama dev
mix releaser.bump minor --mode prerelease --tag dev   # 1.0.0 → 1.1.0-dev.1

# Iterar en dev (mismo base, incrementa pre_num)
mix releaser.bump patch --mode prerelease --tag dev   # 1.1.0-dev.1 → 1.1.0-dev.2

# Promover a beta
mix releaser.bump --mode prerelease --tag beta        # 1.1.0-dev.3 → 1.1.0-beta.1

# Release a main
mix releaser.bump release                             # 1.1.0-beta.1 → 1.1.0
```

## GitHub Actions en modo manual

El template incluido en `.github/workflows/release.yml` usa
`--from-commits`, que requiere Conventional Commits. Si no quieres
adoptarlos, tienes dos opciones:

**(a) Borra el workflow** — quedas con flujo 100% local.

**(b) Adáptalo a disparo manual** con `workflow_dispatch`:

```yaml
on:
  workflow_dispatch:
    inputs:
      bump_type:
        description: 'major, minor, or patch'
        required: true
        type: choice
        options: [patch, minor, major]

jobs:
  release:
    # ... checkout, setup-beam, etc.
    - run: mix releaser.bump ${{ inputs.bump_type }} --no-hooks
    - run: |
        git config user.name "github-actions[bot]"
        git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
        VERSION=$(grep '^  @version' mix.exs | sed 's/.*"\(.*\)"/\1/')
        git add -A
        git commit -m "Release v$VERSION"
        git tag "v$VERSION"
        git push && git push --tags
```

Así disparas releases desde la UI de GitHub (Actions → Run workflow) en
lugar de automáticamente en cada push.

## Cuándo usar manual vs Conventional Commits

**Usa manual cuando:**

- El equipo es pequeño y se comunica fácil sobre releases.
- El formato de commits no es parte del workflow de revisión.
- Quieres control total sobre cuándo bumpea cada tipo.
- No usas branches `dev`/`beta` separadas.

**Usa Conventional Commits cuando:**

- Varios devs contribuyen y quieres evitar decisiones manuales.
- Publicas a Hex regularmente y necesitas trazabilidad.
- Tienes un workflow gitflow con `dev`/`beta`/`main`.
- Ya usas `feat:`/`fix:` por costumbre.

Ambos caminos son de primera clase — el que elijas dependerá de tu
equipo y proyecto. Puedes empezar manual y migrar a Conventional
Commits después sin romper nada (la config es aditiva).
