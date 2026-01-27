import ArgumentParser

@main
struct DogecoinNodeSync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dogecoin header management CLI",
        discussion: """
            A unified tool for syncing, exporting, verifying, and inspecting Dogecoin block headers.

            Commands:
              sync     - Download headers from the Dogecoin peer network (default)
              export   - Export headers to a portable bundle file
              verify   - Validate a header cache file
              inspect  - Print info about a header cache file

            Examples:
              DogecoinNodeSync sync --network mainnet
              DogecoinNodeSync export --network mainnet --output ./headers
              DogecoinNodeSync verify ./headers
              DogecoinNodeSync inspect ./headers
            """,
        subcommands: [
            SyncCommand.self,
            ExportCommand.self,
            VerifyCommand.self,
            InspectCommand.self,
        ],
        defaultSubcommand: SyncCommand.self
    )
}
