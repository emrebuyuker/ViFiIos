//
//  UniversityViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 13.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import Firebase
import FirebaseDatabase

class UniversityViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    @IBOutlet weak var universityTableView: UITableView!
    
    var universitiesNameArray = [String]()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.universityTableView.delegate = self
        self.universityTableView.dataSource = self
        
        getDataFromFireBase()
    }
    
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        
        dataBaseRefence.child("Universities").observe(DataEventType.childAdded) { (snapshot) in
            self.universitiesNameArray.append(snapshot.key)
            print(self.universitiesNameArray)
            self.universityTableView.reloadData()
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        print(self.universitiesNameArray)
        return self.universitiesNameArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = universityTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! UniversityTableViewCell
        cell.universityLabel.text = universitiesNameArray[indexPath.row]
        return cell
    }
}
