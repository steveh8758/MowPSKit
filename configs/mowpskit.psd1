@{
    General = @{
        Name = 'MowPSKit'

        Prefix = ''
        CommandSeparator = ''
    }

    Build = @{
        SourcePath = 'src'
        OutputPath = 'dist\MowPSKit.ps1'

        ArtifactUrl = 'https://raw.githubusercontent.com/steveh8758/MowPSKit/main/dist/MowPSKit.ps1'
        SetupUrl    = 'https://raw.githubusercontent.com/steveh8758/MowPSKit/main/setup.ps1'
    }

    Normalize = @{
        Path = 'src'

        Encoding = 'UTF8NoBOM'
        LineEnding = 'CRLF'

        Extensions = @(
            '.ps1'
            '.psm1'
            '.psd1'
            '.json'
            '.txt'
        )

        ExcludeDirs = @(
            '.git'
            '.github'
            '.venv'
            'venv'
            'node_modules'
        )
    }
}
