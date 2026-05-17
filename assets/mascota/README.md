# Assets de mascota (Cachu)

Este directorio define la ubicación oficial de los SVG para la mascota.

Archivos requeridos:

- `Cachu.svg` (estado neutro)
- `CachuFeliz.svg` (estado positivo)
- `CachuTriste.svg` (estado negativo)

Guía permanente para colaboradores: si los archivos finales llegan con variación de extensión (`.Svg` o `.SVG`), el responsable de integrar assets en el PR debe renombrarlos a `.svg` antes del commit para mantener consistencia en rutas.

Validación recomendada antes de commit:

```bash
find assets/mascota -type f \( -name "*.Svg" -o -name "*.SVG" \)
```

El comando debe retornar vacío para cumplir el estándar de nomenclatura.

Opcional para enforcement local automático:

```bash
git config core.hooksPath .githooks
```
