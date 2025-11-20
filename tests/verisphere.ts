import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { Verisphere } from "../target/types/verisphere";

describe("verisphere", () => {
  // Configure the client to use the local cluster.
  anchor.setProvider(anchor.AnchorProvider.env());

  const program = anchor.workspace.Verisphere as Program<Verisphere>;

  it("Initializes a post!", async () => {
    // Placeholder test for initialize_post
    await program.methods.initializePost(new anchor.BN(1)).rpc();
  });

  it("Stakes on a post!", async () => {
    // Placeholder test for stake
    await program.methods.stake(new anchor.BN(1), true).rpc();
  });
});
