"use client";

import Buy from "@/components/buy";
import Claim from "@/components/claim";
import { Button } from "@/components/ui/button";
import { parseEther } from "viem";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useSendTransaction,
} from "wagmi";

function App() {
  const account = useAccount();
  const { connectors, connect, status, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { data, error: sendError, sendTransactionAsync } = useSendTransaction();
  return (
    <>
      <div>
        <h2>Account</h2>
        <h1 className="text-3xl font-bold underline">Hello world!</h1>
        <div>
          Status: {account.status}
          <br />
          Sub Account Address: {JSON.stringify(account.addresses)}
          <br />
          Chain ID: {account.chainId}
        </div>

        {account.status === "connected" && (
          <Button type="button" onClick={() => disconnect()}>
            Disconnect
          </Button>
        )}
      </div>

      <div>
        <h2>Connect</h2>
        {connectors
          .filter((connector) => connector.name === "Coinbase Wallet")
          .map((connector) => (
            <Button
              key={connector.uid}
              onClick={() => connect({ connector })}
              type="button"
            >
              Sign in with Smart Wallet
            </Button>
          ))}
        <div>{status}</div>
        <div>{error?.message}</div>
      </div>
      <div>
        <div>Send Transaction</div>
        <button
          type="button"
          onClick={async () =>
            sendTransactionAsync({
              to: "0x4e6D595987572f20847a0bF739FC0d9bE32a98a2",
              value: parseEther("0.00001"),
            })
          }
        >
          Send Transaction
        </button>
        <div>{data && "Transaction sent successfully! 🎉"}</div>
        <div>{data}</div>
      </div>
      <Buy />
      <Claim />
    </>
  );
}

export default App;
