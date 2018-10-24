/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

//define the type Neighbor with the Node ID and number of pings to it
typedef nx_struct Neighbor {
   nx_uint16_t Node;
   nx_uint16_t pingNumber;
}Neighbor;

typedef nx_struct LinkState {
   nx_uint16_t Dest;
   nx_uint16_t Cost;
   nx_uint16_t Next;
   nx_uint16_t Seq;
   nx_uint8_t Neighbors[64];
   nx_uint16_t NeighborsLength;
}LinkState;

module Node{
   uses interface Boot;

   //list of packets to determine if a node has seen or sent this packet before
   uses interface List<pack> as MarkedPackets;
   //timer to use to fire packets
   uses interface Timer<TMilli> as PeriodicTimer;
   //random number used for timer to make sure it's spaced
   uses interface Random as Random;
   //list of neighboring nodes as seen by current node
   uses interface List<Neighbor> as Neighbors;
   //list of removed nodes from the neighbor list
   uses interface List<Neighbor> as NeighborsDropped;
   //list of nodes and their costs
   uses interface List<Neighbor> as NeighborCosts;
   //routing table to be used by nodes
   uses interface List<LinkState> as RoutingTable;
   uses interface SplitControl as AMControl;
   uses interface Receive;

   uses interface SimpleSend as Sender;

   uses interface CommandHandler;

}

implementation{
   pack sendPackage;
   uint16_t seqCounter = 0;
   uint16_t accessCounter = 0;
   uint32_t difference = 0;
   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   //puts a packet into the list at the top
   void pushPack(pack Package);
   //finds a packet in the list
   bool findPack(pack *Package);
   //access neighbor list
   void accessNeighbors();
   //starts to flood the LSP packet
   void floodLSP();

   event void Boot.booted(){
      uint32_t initial;
      uint32_t change;
      call AMControl.start();
      dbg(GENERAL_CHANNEL, "Booted\n");
      //create an initial time to start firing from between 0-999 milliseconds
      initial = call Random.rand32() % 1000;
      //change is the interval to fire between each fire from 10000-25000 milliseconds
      change = 10000 + (call Random.rand32() % 15000);
      //start the timer
      call PeriodicTimer.startPeriodicAt(initial, change);
      //dbg(GENERAL_CHANNEL, "Timer started at %d, firing interval %d\n", initial, change);
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         //Retry until successful
         call AMControl.start();
      }
   }

   event void PeriodicTimer.fired() {
	accessNeighbors();
	if (accessCounter > 1 && accessCounter % 5 == 0 && accessCounter < 6)
		floodLSP();
   }


   event void AMControl.stopDone(error_t err){}

	event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
		//dbg(FLOODING_CHANNEL, "Packet Received\n");
		if(len==sizeof(pack)){
			//creates a message with the payload, or message, of the recieved packet
			pack* myMsg=(pack*) payload;
			//check to see if this packet needs to be dropped, either through checking to see if the TTL expired, or if it was listed in the list of sent or seen packets
			if((myMsg->TTL == 0) || findPack(myMsg)){
				//drops packet by doing nothing and not sending out a new packet
			}
			//else, check to see if the packet is checking for neighbors, deal with it seperately
			else if(myMsg->dest == AM_BROADCAST_ADDR) {
				bool found;
				bool match;
				uint16_t length;
				uint16_t i = 0;
				Neighbor Neighbor1,Neighbor2,NeighborCheck;
				//if the packet is sent to ping for neighbors
				if (myMsg->protocol == PROTOCOL_PING){
					//send a packet that expects replies for neighbors
					//dbg(NEIGHBOR_CHANNEL, "Packet sent from %d to check for neighbors\n", myMsg->src);
					makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, myMsg->TTL-1, PROTOCOL_PINGREPLY, myMsg->seq, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
					pushPack(sendPackage);
					call Sender.send(sendPackage, myMsg->src);
				}
				//if the packet is sent to ping for replies
				else if (myMsg->protocol == PROTOCOL_PINGREPLY){
					//update ping number, search and see if the neighbor was found
					//dbg(NEIGHBOR_CHANNEL, "Packet recieved from %d, replying\n", myMsg->src);
					length = call Neighbors.size();
					found = FALSE;
					for (i = 0; i < length; i++){
						Neighbor2 = call Neighbors.get(i);
						//dbg(GENERAL_CHANNEL, "Pings at %d = %d\n", Neighbor2.Node, Neighbor2.pingNumber);
						if (Neighbor2.Node == myMsg->src) {
							//dbg(NEIGHBOR_CHANNEL, "Node found, adding %d to list\n", myMsg->src);
							//reset the ping number if found to keep it from being dropped
							Neighbor2.pingNumber = 0;
							found = TRUE;
						}
					}
				}
				//if the packet is sent to find other nodes
				else if (myMsg->protocol == PROTOCOL_LINKSTATE) {
					//store the LSP in a list of structs
					LinkState LSP;
					LinkState temp;
					bool end;
					bool end2;
					uint16_t j;
					uint16_t k;
					uint16_t count = 0;
					end = TRUE;
					end2 = TRUE;
					i = 0;
					LSP.Dest = myMsg->src;
					LSP.Cost = MAX_TTL - myMsg->TTL;
					LSP.Next = myMsg->src;
					LSP.Seq = myMsg->seq;
					while (end){
						if (myMsg->payload[i] < 1) {
							LSP.Neighbors[i] = 0;
							end = FALSE;
							break;
						}
						//else if (
						else {
							LSP.Neighbors[i] = myMsg->payload[i];
							count++;
							dbg(ROUTING_CHANNEL, "Recieved info on %d, has neighbor %d with cost %d, next is %d\n", LSP.Dest, LSP.Neighbors[i], LSP.Cost, LSP.Next);
						}
						i++;
					}
					LSP.NeighborsLength = count;
					call RoutingTable.pushback(LSP);
					//dbg(ROUTING_CHANNEL, "Table for %d: \n", TOS_NODE_ID);
					j = 0;
					k = 0;
					while (end2){
						temp = call RoutingTable.get(j);
						if (temp.Neighbors[k] < 1) {
							end2 = FALSE;
							break;
						}
						//dbg(ROUTING_CHANNEL, "LSP from %d has Neighbor: %d, Cost: %d, Next: %d, Seq: %d\n", temp.Dest, temp.Neighbors[k], temp.Cost, temp.Next, temp.Seq);
						j++;
						k++;
					}
					makePack(&sendPackage, myMsg->src, AM_BROADCAST_ADDR, myMsg->TTL-1, PROTOCOL_LINKSTATE, myMsg->seq, (uint8_t *)myMsg->payload, (uint8_t) sizeof(myMsg->payload));
					pushPack(sendPackage);
					call Sender.send(sendPackage, AM_BROADCAST_ADDR);
				}
				//if we didn't find a match
				if (!found && myMsg->protocol != PROTOCOL_LINKSTATE){
					//add it to the list, using the memory of a previous dropped node

					Neighbor1 = call NeighborsDropped.get(0);
					//check to see if already in list
					length = call Neighbors.size();
					for (i = 0; i < length; i++){
						NeighborCheck = call Neighbors.get(i);
						if (myMsg->src == NeighborCheck.Node){
							match = TRUE;
						}
					}
					if (match == TRUE) {
						//already in the list, no need to repeat
					}
					else {
						//not in list, so we're going to add it
						//dbg(NEIGHBOR_CHANNEL, "%d not found, put in list\n", myMsg->src);
						LinkState temp;
						Neighbor1.Node = myMsg->src;
						Neighbor1.pingNumber = 0;
						call Neighbors.pushback(Neighbor1);

					}
				}
			}
 			//else, check to see if the packet reached it's destination and see what the purpose/protocal of the packet was
			else if((myMsg->dest == TOS_NODE_ID) && myMsg->protocol == PROTOCOL_PING) {
				//when protocal = PROTOCAL_PING, the packet was sent as a ping, and not a reply
				dbg(FLOODING_CHANNEL, "Packet is at destination! Package Payload: %s\n", myMsg->payload);
				//make another packet that's the reply from the ping
				makePack(&sendPackage, TOS_NODE_ID, myMsg->src, MAX_TTL, PROTOCOL_PINGREPLY, seqCounter, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
				//increase the sequence number of the next packet that will be sent
				seqCounter++;
				//put the packet into the list
				pushPack(sendPackage);
				//send the new packet
				call Sender.send(sendPackage, AM_BROADCAST_ADDR);
			}
			else if((myMsg->dest == TOS_NODE_ID) && myMsg->protocol == PROTOCOL_PINGREPLY) {
				//the packet is at the right destination, and it is simply a reply, we can stop sending the packet here
				dbg(FLOODING_CHANNEL, "Recieved a reply it was delivered from %d!\n", myMsg->src);
			}
			else {
				//all else, wrong destination, flood the packet
				makePack(&sendPackage, myMsg->src, myMsg->dest, myMsg->TTL-1, myMsg->protocol, myMsg->seq, (uint8_t *)myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
				pushPack(sendPackage);
				call Sender.send(sendPackage, AM_BROADCAST_ADDR);
			}
			return msg;
		}
		else {
		//all else, we dunno what the packet was to do
		dbg(GENERAL_CHANNEL, "Unknown Packet Use, Error with: %d\n", len);
		return msg;
		}
	}


   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      dbg(GENERAL_CHANNEL, "PING EVENT \n");
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, 0, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
      call Sender.send(sendPackage, AM_BROADCAST_ADDR);
   }

   event void CommandHandler.printNeighbors(){
	uint16_t i = 0;
	uint16_t length = call Neighbors.size();
	Neighbor beingPrinted;
	if (length == 0){
		dbg(NEIGHBOR_CHANNEL, "No neighbors exist\n");
	}
	else {
		for (i = 0; i < length; i++){
			beingPrinted = call Neighbors.get(i);
			dbg(NEIGHBOR_CHANNEL, "Neighbor at %d\n", beingPrinted.Node, i);
			}
	}
   }

   event void CommandHandler.printRouteTable(){}

   event void CommandHandler.printLinkState(){}

   event void CommandHandler.printDistanceVector(){}

   event void CommandHandler.setTestServer(){}

   event void CommandHandler.setTestClient(){}

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }

   void accessNeighbors() {
	//make a packet to send to check neighbors
	pack Pack;
	//test message to be sent
	char* message;
	//increase the access counter
	accessCounter++;
	//dbg(NEIGHBOR_CHANNEL, "Neighbors accessed, %d is checking.\n", TOS_NODE_ID);
	//check to see if neighbors have been found at all
	if (!(call Neighbors.isEmpty())) {
		uint16_t length = call Neighbors.size();
		uint16_t pings = 0;
		Neighbor NeighborNode;
		uint16_t i = 0;
		Neighbor temp;
		//increase the number of pings in the neighbors in the list. if the ping number is greater than 3, drop the neighbor
		for (i = 0; i < length; i++){
			temp = call Neighbors.get(i);
			temp.pingNumber = temp.pingNumber + 1;
			pings = temp.pingNumber;
			//dbg(ROUTING_CHANNEL, "Pings at %d: %d\n", temp.Node, pings);
			if (pings > 3){
				NeighborNode = call Neighbors.removeFromList(i);
				dbg(NEIGHBOR_CHANNEL, "Node %d dropped due to more than 3 pings\n", NeighborNode.Node);
				call NeighborsDropped.pushfront(NeighborNode);
				i--;
				length--;
			}
		}
	}
	//ping the list of Neighbors
	message = "pinged neighbors!\n";
	makePack(&Pack, TOS_NODE_ID, AM_BROADCAST_ADDR, 2, PROTOCOL_PING, 1, (uint8_t*) message, (uint8_t) sizeof(message));
	//add the packet to the packet list
	pushPack(Pack);
	//send the packet
	call Sender.send(Pack, AM_BROADCAST_ADDR);
   }

	void pushPack(pack Package) {
		//check to see if the list is full; if so, remove the oldest node
		if (call MarkedPackets.isFull()) {
			call MarkedPackets.popfront();
		}
		call MarkedPackets.pushback(Package);
	}

	bool findPack(pack *Package) {
		uint16_t size = call MarkedPackets.size();
		uint16_t i = 0;
		pack match;
		for (i = 0; i < size; i++) {
			match = call MarkedPackets.get(i);
			if((match.src == Package->src) && (match.dest == Package->dest) && (match.seq == Package->seq)) {
				return TRUE;
			}
		}
		return FALSE;
	}

	void floodLSP(){
		//run to flood LSPs, sending info of this node's direct neighbors
		pack LSP;
		//dbg(ROUTING_CHANNEL, "LSP Initial Flood from %d\n", TOS_NODE_ID);
		//check to see if there are neighbors to at all
		if (!call Neighbors.isEmpty()){
			uint16_t i = 0;
			uint16_t length = call Neighbors.size();
			uint16_t directNeighbors[length+1];
			Neighbor temp;

			//move the neighbors into the array
			for (i = 0; i < length; i++) {
				temp = call Neighbors.get(i);
				directNeighbors[i] = temp.Node;
			}

			//set a negative number to tell future loops to stop!
			directNeighbors[length] = 0;
			//dbg(ROUTING_CHANNEL, "this should be 0: %d\n", directNeighbors[length]);

			//start flooding the packet
			makePack(&LSP, TOS_NODE_ID, AM_BROADCAST_ADDR, MAX_TTL-1, PROTOCOL_LINKSTATE, seqCounter, (uint8_t*)directNeighbors, (uint8_t) sizeof(directNeighbors));
			pushPack(LSP);
			call Sender.send(LSP, AM_BROADCAST_ADDR);
		}
	}
}
