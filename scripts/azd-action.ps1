function Get-AzdCommandAction([string[]]$Arguments) {
    if ($Arguments.Count -lt 2) { throw 'Missing azd command.' }
    $index = 1
    while ($index -lt $Arguments.Count) {
        $argument = $Arguments[$index]
        if ($argument -in @('-C', '--cwd', '-e', '--environment')) {
            if ($index + 1 -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace($Arguments[$index + 1])) {
                throw 'Missing azd global option value.'
            }
            $index += 2
            continue
        }
        if ($argument -match '^(--cwd|--environment)=.+' -or
            $argument -in @('--no-prompt', '--debug')) {
            $index++
            continue
        }
        if ($argument -in @('up', 'down')) { return $argument }
        throw 'Unsupported or independently invoked azd command.'
    }
    throw 'Missing azd command.'
}
