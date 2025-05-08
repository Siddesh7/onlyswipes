import React from "react";
import { parseEther } from "viem";
import { useAccount, useSendTransaction, useWriteContract } from "wagmi";
import onlyswipes from "@/contracts/onlyswipes.abi.json";
import { Button } from "./ui/button";
import { PREDICTION_CONTRACT } from "@/constants";

const Claim = () => {
  const { data, error: sendError, writeContractAsync } = useWriteContract();
  const { addresses } = useAccount();
  return (
    <div>
      <div>claim</div>
      <Button
        type="button"
        onClick={async () =>
          writeContractAsync({
            abi: onlyswipes,
            functionName: "claimWinnings",
            args: [0, addresses[1]!],
            address: PREDICTION_CONTRACT,
          })
        }
      >
        claim
      </Button>
      <div>{data && "Transaction sent successfully! 🎉"}</div>
      <div>{data}</div>
      {sendError && <div>{JSON.stringify(sendError)}</div>}
    </div>
  );
};

export default Claim;
